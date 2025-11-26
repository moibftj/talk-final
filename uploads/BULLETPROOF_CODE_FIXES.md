# Talk-to-my-Lawyer: Bulletproof Code Fixes

This document contains all the TypeScript/React code changes needed to make the application production-ready.

## Fix 1: TALK3 Coupon Handling in subscription-card.tsx

**File:** `components/subscription-card.tsx`

**Problem:** The coupon validation only checks the database, but TALK3 needs special handling for 100% discount.

**Replace the `handleApplyCoupon` function (lines 56-92):**

```typescript
const handleApplyCoupon = async (code?: string) => {
  const coupon = (code || couponCode).toUpperCase().trim()
  if (!coupon) return

  setLoading(true)
  setError(null)

  try {
    // Check employee coupons in database (this now includes TALK3)
    const { data, error } = await supabase
      .from('employee_coupons')
      .select('*')
      .eq('code', coupon)
      .eq('is_active', true)
      .single()

    if (error || !data) {
      setError('Invalid coupon code')
      setCouponApplied(false)
      setDiscount(0)
      return
    }

    const plan = PLANS.find(p => p.id === selectedPlan)
    if (plan) {
      const discountAmount = (plan.price * data.discount_percent) / 100
      setDiscount(discountAmount)
      setCouponApplied(true)
      setError(null)
    }
  } catch (err) {
    setError('Failed to apply coupon')
    setCouponApplied(false)
  } finally {
    setLoading(false)
  }
}
```

**Note:** This now works because the SQL migration adds TALK3 to the employee_coupons table with 100% discount.

---

## Fix 2: Free Trial Logic in new/page.tsx

**File:** `app/dashboard/letters/new/page.tsx`

**Problem:** The `checkSubscription` function blocks free trial users from generating their first letter.

**Replace the `checkSubscription` function (lines 105-139):**

```typescript
const checkSubscription = async () => {
  setIsChecking(true)
  try {
    const supabase = createClient()
    const { data: { user } } = await supabase.auth.getUser()

    if (!user) {
      setIsChecking(false)
      return
    }

    // CRITICAL FIX: Check if user has any letters (free trial check)
    const { count: letterCount, error: countError } = await supabase
      .from('letters')
      .select('*', { count: 'exact', head: true })
      .eq('user_id', user.id)

    if (countError) {
      console.error('Error counting letters:', countError)
    }

    // If user has no letters, they qualify for free trial
    if ((letterCount || 0) === 0) {
      setHasSubscription(true) // Allow free trial
      setIsChecking(false)
      return
    }

    // Otherwise, check for active subscription with credits
    const { data: subscriptions, error } = await supabase
      .from('subscriptions')
      .select('credits_remaining, remaining_letters, status')
      .eq('user_id', user.id)
      .eq('status', 'active')
      .order('created_at', { ascending: false })
      .limit(1)

    if (error) {
      console.error('Error fetching subscription:', error)
      setHasSubscription(false)
      return
    }

    const subscription = subscriptions?.[0]
    // Check both credit fields for backwards compatibility
    const hasCredits = subscription && (
      (subscription.credits_remaining || 0) > 0 || 
      (subscription.remaining_letters || 0) > 0
    )
    setHasSubscription(!!hasCredits)
  } catch (error) {
    console.error('Error checking subscription:', error)
    setHasSubscription(false)
  } finally {
    setIsChecking(false)
  }
}
```

---

## Fix 3: Hide AI Draft Before Approval in [id]/page.tsx

**File:** `app/dashboard/letters/[id]/page.tsx`

**Problem:** AI draft content is shown to subscribers before admin approval.

**Replace the letter content section (lines 177-198) with:**

```tsx
{/* Letter Content - Only show after approval */}
{letter.status === 'approved' ? (
  <>
    {/* Show Final Content if available */}
    {letter.admin_edited_content || letter.final_content ? (
      <div className="bg-white rounded-lg shadow-sm border p-6 space-y-4">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold">Your Approved Letter</h2>
          <span className="text-xs text-primary font-medium">Approved</span>
        </div>
        <div className="bg-muted/50 border rounded-lg p-4">
          <pre className="whitespace-pre-wrap text-sm leading-relaxed">
            {letter.admin_edited_content || letter.final_content}
          </pre>
        </div>
      </div>
    ) : (
      <div className="bg-white rounded-lg shadow-sm border p-6 space-y-4">
        <div className="flex items-center justify-between">
          <h2 className="text-lg font-semibold">Attorney Draft</h2>
          <span className="text-xs text-primary font-medium">Approved</span>
        </div>
        <div className="bg-muted/50 border rounded-lg p-4">
          <pre className="whitespace-pre-wrap text-sm leading-relaxed">
            {letter.ai_draft_content || 'No content available.'}
          </pre>
        </div>
      </div>
    )}
  </>
) : (
  /* Before approval - show placeholder message */
  <div className="bg-white rounded-lg shadow-sm border p-6">
    <div className="flex items-center justify-between mb-4">
      <h2 className="text-lg font-semibold">Letter Content</h2>
      <span className="text-xs text-muted-foreground">Pending Review</span>
    </div>
    <div className="bg-muted/30 border border-dashed rounded-lg p-8 text-center">
      <svg className="w-12 h-12 text-muted-foreground mx-auto mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
      </svg>
      <h3 className="font-medium text-foreground mb-2">Content Under Review</h3>
      <p className="text-sm text-muted-foreground max-w-md mx-auto">
        Your letter is being reviewed by our legal team. 
        The content will be available here once approved.
      </p>
    </div>
  </div>
)}
```

---

## Fix 4: Admin Session Validation in admin-session.ts

**File:** `lib/auth/admin-session.ts`

**Add validation at the start of the file:**

```typescript
// Validate admin configuration on module load
const ADMIN_EMAIL = process.env.ADMIN_EMAIL
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD  
const ADMIN_PORTAL_KEY = process.env.ADMIN_PORTAL_KEY

if (!ADMIN_EMAIL || !ADMIN_PASSWORD || !ADMIN_PORTAL_KEY) {
  console.warn('[SECURITY WARNING] Admin credentials not configured. Admin portal will be disabled.')
}

export function isAdminConfigured(): boolean {
  return !!(ADMIN_EMAIL && ADMIN_PASSWORD && ADMIN_PORTAL_KEY)
}
```

**Update the login route (`app/api/admin-auth/login/route.ts`):**

Add at the start of the POST handler:

```typescript
import { isAdminConfigured } from '@/lib/auth/admin-session'

export async function POST(request: NextRequest) {
  // Check if admin is configured
  if (!isAdminConfigured()) {
    return NextResponse.json(
      { error: 'Admin system not configured. Please contact support.' },
      { status: 503 }
    )
  }
  
  // ... rest of the handler
}
```

---

## Fix 5: Verify Payment Service Role Key

**File:** `app/api/verify-payment/route.ts`

**Problem:** Uses wrong environment variable name `SERVICE_ROLE_KEY` instead of `SUPABASE_SERVICE_ROLE_KEY`.

**Fix line 9-12:**

```typescript
// Use the correct environment variable name
const supabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY! // Fixed variable name
)
```

---

## Fix 6: Enhanced Error Handling in create-checkout/route.ts

**File:** `app/api/create-checkout/route.ts`

**Add input validation at the start of the POST handler (after line 18):**

```typescript
// Validate input
if (!planType || typeof planType !== 'string') {
  return NextResponse.json(
    { error: 'Invalid plan type' },
    { status: 400 }
  )
}

// Validate plan type is one of the allowed values
const validPlanTypes = ['one_time', 'standard_4_month', 'premium_8_month']
if (!validPlanTypes.includes(planType)) {
  return NextResponse.json(
    { error: 'Invalid plan type. Must be one of: ' + validPlanTypes.join(', ') },
    { status: 400 }
  )
}

// Sanitize coupon code if provided
const sanitizedCouponCode = couponCode 
  ? couponCode.toString().toUpperCase().trim().slice(0, 20) 
  : null
```

Then use `sanitizedCouponCode` instead of `couponCode` throughout the handler.

---

## Fix 7: Add Missing Columns to TypeScript Types

**File:** `lib/database.types.ts`

**Update the Subscription interface:**

```typescript
export interface Subscription {
  id: string
  user_id: string
  plan: string
  plan_type: string | null
  status: SubscriptionStatus
  price: number
  discount: number
  coupon_code: string | null
  credits_remaining: number
  remaining_letters: number
  last_reset_at: string | null
  stripe_session_id: string | null
  current_period_start: string | null
  current_period_end: string | null
  created_at: string
  updated_at: string
}
```

**Update the CouponUsage interface:**

```typescript
export interface CouponUsage {
  id: string
  user_id: string
  employee_id: string | null
  coupon_code: string
  discount_percent: number
  amount_before: number
  amount_after: number
  created_at: string
}
```

---

## Summary of All Changes

| File | Fix Description | Priority |
|------|-----------------|----------|
| `supabase/migrations/012_*.sql` | Add TALK3 coupon, fix tables | CRITICAL |
| `components/subscription-card.tsx` | Coupon validation | CRITICAL |
| `app/dashboard/letters/new/page.tsx` | Free trial logic | CRITICAL |
| `app/dashboard/letters/[id]/page.tsx` | Hide AI draft | HIGH |
| `lib/auth/admin-session.ts` | Config validation | HIGH |
| `app/api/verify-payment/route.ts` | Env var fix | HIGH |
| `app/api/create-checkout/route.ts` | Input validation | MEDIUM |
| `lib/database.types.ts` | Type updates | LOW |

---

## Deployment Checklist

1. ✅ Run the SQL migration in Supabase SQL Editor
2. ✅ Apply TypeScript code fixes
3. ✅ Verify environment variables in Vercel:
   - `SUPABASE_SERVICE_ROLE_KEY` (not `SERVICE_ROLE_KEY`)
   - `ADMIN_EMAIL`
   - `ADMIN_PASSWORD`
   - `ADMIN_PORTAL_KEY`
4. ✅ Test TALK3 coupon flow
5. ✅ Test free trial for new users
6. ✅ Test letter status visibility
7. ✅ Test admin login

---

## Testing Commands

```bash
# Test TALK3 coupon in Supabase
SELECT * FROM employee_coupons WHERE code = 'TALK3';

# Verify coupon_usage table structure
\d coupon_usage

# Test validate_coupon function
SELECT * FROM validate_coupon('TALK3');

# Verify subscription credits columns
SELECT id, credits_remaining, remaining_letters FROM subscriptions LIMIT 5;
```
