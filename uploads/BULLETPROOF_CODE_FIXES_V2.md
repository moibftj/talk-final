# Talk-to-my-Lawyer: Bulletproof Code Fixes (v2)

**Aligned with:** `PLATFORM_ARCHITECTURE.md`

This document contains all the TypeScript/React code changes needed to make the application production-ready, following the complete workflow defined in your architecture document.

---

## Letter Status Lifecycle (per Architecture)

```
draft → generating → pending_review → under_review → approved → completed
                                                   ↘ rejected
```

**Special Status:** `failed` (when generation fails)

---

## Fix 1: Free Trial Logic in `app/dashboard/letters/new/page.tsx`

**Problem:** The `checkSubscription` function blocks free trial users from generating their first letter.

**Architecture Reference:**
> STEP 2: Free Trial Check
> ```typescript
> const { count } = await supabase.from('letters').select('*', { count: 'exact', head: true }).eq('user_id', user.id)
> const isFreeTrial = (count || 0) === 0
> ```

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

    // =========================================
    // CRITICAL FIX: Check for Free Trial first
    // Per architecture: isFreeTrial = (letterCount === 0)
    // =========================================
    const { count: letterCount, error: countError } = await supabase
      .from('letters')
      .select('*', { count: 'exact', head: true })
      .eq('user_id', user.id)

    if (countError) {
      console.error('Error counting letters:', countError)
    }

    // If user has no letters, they qualify for FREE TRIAL
    // This allows them to generate their first letter without a subscription
    if ((letterCount || 0) === 0) {
      setHasSubscription(true) // Allow free trial generation
      setIsChecking(false)
      return
    }

    // =========================================
    // For users with existing letters, check subscription
    // =========================================
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

## Fix 2: Hide AI Draft Before Approval in `app/dashboard/letters/[id]/page.tsx`

**Problem:** AI draft content is shown to subscribers before admin approval.

**Architecture Reference:**
> Before approval:
> - Show timeline only + statuses like `pending_review`, `under_review`.
> - Do **not** show AI draft.
> 
> After approval (`approved` or `completed`):
> - Show `final_content` (admin-edited version)

**Replace the letter content section (lines 177-198) with:**

```tsx
{/* Letter Content Section */}
{['approved', 'completed'].includes(letter.status) ? (
  <>
    {/* Show Final/Approved Content */}
    <div className="bg-white rounded-lg shadow-sm border p-6 space-y-4">
      <div className="flex items-center justify-between">
        <h2 className="text-lg font-semibold">Your Approved Letter</h2>
        <span className="text-xs text-primary font-medium capitalize">
          {letter.status === 'completed' ? 'Completed' : 'Approved'}
        </span>
      </div>
      <div className="bg-muted/50 border rounded-lg p-4">
        <pre className="whitespace-pre-wrap text-sm leading-relaxed">
          {/* Priority: admin_edited_content > final_content > ai_draft_content */}
          {letter.admin_edited_content || letter.final_content || letter.ai_draft_content || 'No content available.'}
        </pre>
      </div>
    </div>
    
    {/* Show review notes if any */}
    {letter.review_notes && (
      <div className="bg-muted/30 border rounded-lg p-4 mt-4">
        <h3 className="text-sm font-medium text-muted-foreground mb-2">Attorney Notes</h3>
        <p className="text-sm">{letter.review_notes}</p>
      </div>
    )}
  </>
) : (
  /* Before approval - show placeholder message */
  <div className="bg-white rounded-lg shadow-sm border p-6">
    <div className="flex items-center justify-between mb-4">
      <h2 className="text-lg font-semibold">Letter Content</h2>
      <span className="text-xs text-muted-foreground capitalize">
        {letter.status.replace('_', ' ')}
      </span>
    </div>
    <div className="bg-muted/30 border border-dashed rounded-lg p-8 text-center">
      <svg className="w-12 h-12 text-muted-foreground mx-auto mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24">
        <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={1.5} d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z" />
      </svg>
      <h3 className="font-medium text-foreground mb-2">Content Under Review</h3>
      <p className="text-sm text-muted-foreground max-w-md mx-auto">
        {letter.status === 'generating' 
          ? 'Your letter is being generated. This may take a moment...'
          : letter.status === 'under_review'
            ? 'An attorney is currently reviewing your letter.'
            : letter.status === 'rejected'
              ? 'Your letter was rejected. Please check the rejection reason below.'
              : 'Your letter is in the review queue. Content will be available once approved.'}
      </p>
    </div>
  </div>
)}
```

---

## Fix 3: Update Timeline Steps Logic

**In the same file (`app/dashboard/letters/[id]/page.tsx`), update the timeline steps (around lines 37-70):**

```tsx
const timelineSteps = [
  {
    label: 'Request Received',
    status: 'completed',
    icon: '✓',
    description: format(new Date(letter.created_at), 'MMM d, yyyy h:mm a')
  },
  {
    label: 'Under Attorney Review',
    status: ['pending_review', 'under_review'].includes(letter.status) 
      ? 'active' 
      : (['approved', 'rejected', 'completed'].includes(letter.status) ? 'completed' : 'pending'),
    icon: ['pending_review', 'under_review'].includes(letter.status) ? '⏳' : 
          (['approved', 'rejected', 'completed'].includes(letter.status) ? '✓' : '○'),
    description: letter.status === 'under_review' 
      ? 'Attorney is currently reviewing your letter' 
      : (letter.status === 'pending_review' 
        ? 'Waiting for attorney review' 
        : (['approved', 'completed'].includes(letter.status) 
          ? 'Review completed' 
          : 'Pending'))
  },
  {
    label: letter.status === 'rejected' ? 'Rejected' : 'Approved',
    status: ['approved', 'rejected', 'completed'].includes(letter.status) ? 'completed' : 'pending',
    icon: ['approved', 'completed'].includes(letter.status) ? '✓' : (letter.status === 'rejected' ? '✗' : '○'),
    description: letter.approved_at 
      ? format(new Date(letter.approved_at), 'MMM d, yyyy h:mm a')
      : (letter.reviewed_at && letter.status === 'rejected' 
        ? format(new Date(letter.reviewed_at), 'MMM d, yyyy h:mm a')
        : 'Pending approval')
  },
  {
    label: 'Letter Ready',
    status: ['approved', 'completed'].includes(letter.status) ? 'completed' : 'pending',
    icon: ['approved', 'completed'].includes(letter.status) ? '✓' : '○',
    description: ['approved', 'completed'].includes(letter.status) 
      ? 'Ready to download and email' 
      : 'Waiting for approval'
  }
]
```

---

## Fix 4: Verify Payment Environment Variable

**File:** `app/api/verify-payment/route.ts`

**Problem:** Uses wrong environment variable name.

**Fix line 9-12:**

```typescript
// BEFORE (incorrect):
const supabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.SERVICE_ROLE_KEY!  // ❌ Wrong variable name
)

// AFTER (correct):
const supabase = createClient(
  process.env.NEXT_PUBLIC_SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!  // ✅ Correct variable name
)
```

---

## Fix 5: Admin Session Validation

**File:** `lib/auth/admin-session.ts`

**Problem:** Admin login silently fails if environment variables aren't set.

**Add at the start of the file:**

```typescript
// =========================================
// Validate admin configuration on module load
// =========================================
const ADMIN_EMAIL = process.env.ADMIN_EMAIL
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD  
const ADMIN_PORTAL_KEY = process.env.ADMIN_PORTAL_KEY

// Log warning if admin credentials not configured
if (typeof window === 'undefined') { // Server-side only
  if (!ADMIN_EMAIL || !ADMIN_PASSWORD || !ADMIN_PORTAL_KEY) {
    console.warn('[SECURITY] Admin credentials not fully configured. Admin portal may be disabled.')
  }
}

/**
 * Check if admin authentication is properly configured
 */
export function isAdminConfigured(): boolean {
  return !!(
    process.env.ADMIN_EMAIL && 
    process.env.ADMIN_PASSWORD && 
    process.env.ADMIN_PORTAL_KEY
  )
}
```

**Update the login route (`app/api/admin-auth/login/route.ts`):**

Add at the start of the POST handler:

```typescript
import { isAdminConfigured } from '@/lib/auth/admin-session'

export async function POST(request: NextRequest) {
  // Check if admin is configured
  if (!isAdminConfigured()) {
    console.error('[CRITICAL] Admin credentials not configured in environment variables')
    return NextResponse.json(
      { error: 'Admin system not configured. Please contact support.' },
      { status: 503 }
    )
  }
  
  // ... rest of the existing handler code
}
```

---

## Fix 6: Update TypeScript Types

**File:** `lib/database.types.ts`

**Update the Subscription interface to include all fields:**

```typescript
export interface Subscription {
  id: string
  user_id: string
  plan: string
  plan_type: string | null
  status: SubscriptionStatus
  price: number
  discount: number
  discount_percentage: number | null
  coupon_code: string | null
  credits_remaining: number
  remaining_letters: number
  last_reset_at: string | null
  stripe_session_id: string | null
  stripe_subscription_id: string | null
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
  subscription_id: string | null
  discount_percent: number
  amount_before: number
  amount_after: number
  discount_applied: number  // Computed column
  created_at: string
}
```

**Update the Letter interface to include all status fields:**

```typescript
export interface Letter {
  id: string
  user_id: string
  title: string
  letter_type: string
  status: LetterStatus
  recipient_name: string | null
  recipient_address: string | null
  subject: string | null
  content: string | null
  intake_data: Record<string, any>
  ai_draft_content: string | null
  admin_edited_content: string | null  // Added
  final_content: string | null
  reviewed_content: string | null  // Added
  reviewed_by: string | null
  reviewed_at: string | null
  review_notes: string | null
  rejection_reason: string | null
  approved_at: string | null
  completed_at: string | null  // Added
  sent_at: string | null  // Added
  created_at: string
  updated_at: string
  notes: string | null
}
```

---

## Fix 7: Input Validation in create-checkout/route.ts

**File:** `app/api/create-checkout/route.ts`

**Add input validation after line 18 (after parsing the body):**

```typescript
const body = await request.json()
const { planType, couponCode } = body

// =========================================
// INPUT VALIDATION
// =========================================

// Validate planType is provided and is a string
if (!planType || typeof planType !== 'string') {
  return NextResponse.json(
    { error: 'Plan type is required' },
    { status: 400 }
  )
}

// Validate plan type is one of the allowed values
const validPlanTypes = ['one_time', 'standard_4_month', 'premium_8_month']
if (!validPlanTypes.includes(planType)) {
  return NextResponse.json(
    { error: `Invalid plan type. Must be one of: ${validPlanTypes.join(', ')}` },
    { status: 400 }
  )
}

// Sanitize coupon code if provided (uppercase, trim, max length)
const sanitizedCouponCode = couponCode 
  ? String(couponCode).toUpperCase().trim().slice(0, 50) 
  : null

// Then use sanitizedCouponCode instead of couponCode in the rest of the handler
```

---

## Summary of All Code Changes

| File | Change | Priority | Status |
|------|--------|----------|--------|
| `app/dashboard/letters/new/page.tsx` | Free trial check before subscription check | **CRITICAL** | Apply |
| `app/dashboard/letters/[id]/page.tsx` | Hide AI draft before approval | **CRITICAL** | Apply |
| `app/api/verify-payment/route.ts` | Fix env variable name | **HIGH** | Apply |
| `lib/auth/admin-session.ts` | Add isAdminConfigured() check | **HIGH** | Apply |
| `app/api/admin-auth/login/route.ts` | Check admin configuration | **HIGH** | Apply |
| `lib/database.types.ts` | Update TypeScript interfaces | **MEDIUM** | Apply |
| `app/api/create-checkout/route.ts` | Add input validation | **MEDIUM** | Apply |

---

## Quick Copy-Paste Commands for Claude Code

### Apply Free Trial Fix:
```
In app/dashboard/letters/new/page.tsx, update the checkSubscription function to check letter count FIRST. If user has 0 letters, setHasSubscription(true) to allow free trial. Only check subscription credits if they have existing letters.
```

### Apply Draft Visibility Fix:
```
In app/dashboard/letters/[id]/page.tsx, wrap the letter content display in a conditional. Only show letter content (ai_draft_content, final_content, admin_edited_content) if letter.status is 'approved' or 'completed'. For all other statuses, show a placeholder message saying the letter is under review.
```

### Apply Environment Variable Fix:
```
In app/api/verify-payment/route.ts, change SERVICE_ROLE_KEY to SUPABASE_SERVICE_ROLE_KEY on line 12.
```

---

## Testing After Applying Fixes

### 1. Test Free Trial:
1. Create a new user account
2. Go to "New Letter" page
3. Should be able to fill form and generate WITHOUT subscription
4. Verify letter is created with status `generating` → `pending_review`

### 2. Test Draft Visibility:
1. As a subscriber, view a letter with status `pending_review`
2. Should see "Content Under Review" placeholder, NOT the AI draft
3. After admin approves, should see the final content

### 3. Test TALK3 Coupon:
1. Go to subscription page
2. Enter "TALK3" as coupon code
3. Should show 100% discount ($0 total)
4. Complete checkout (no payment required)
5. User should now have subscription credits

### 4. Test Admin Login:
1. Ensure `ADMIN_EMAIL`, `ADMIN_PASSWORD`, `ADMIN_PORTAL_KEY` are set in Vercel
2. Go to `/secure-admin-gateway/login`
3. Should be able to login with correct credentials
4. Should see 503 error if env vars not set

---

## Verification SQL Queries

Run these in Supabase SQL Editor to verify the migration worked:

```sql
-- 1. Check TALK3 coupon exists with 100% discount
SELECT code, discount_percent, employee_id, is_active 
FROM employee_coupons 
WHERE code = 'TALK3';

-- 2. Check coupon_usage table structure
SELECT column_name, data_type, is_nullable 
FROM information_schema.columns 
WHERE table_name = 'coupon_usage' 
ORDER BY ordinal_position;

-- 3. Check commission trigger exists
SELECT tgname, tgenabled 
FROM pg_trigger 
WHERE tgname = 'create_commission_on_subscription';

-- 4. Verify helper functions exist
SELECT routine_name 
FROM information_schema.routines 
WHERE routine_schema = 'public' 
AND routine_name IN (
  'validate_coupon', 
  'deduct_letter_allowance', 
  'is_admin', 
  'is_super_user'
);

-- 5. Test validate_coupon function
SELECT * FROM validate_coupon('TALK3');
-- Should return: is_valid=true, discount_percent=100, employee_id=null, is_promo_code=true
```
