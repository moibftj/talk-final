# Talk-to-my-Lawyer: Production Deployment Guide (v2)

**Aligned with:** `PLATFORM_ARCHITECTURE.md`

---

## Executive Summary

Your application follows this complete workflow:

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   DRAFT     │ → │ GENERATING  │ → │  PENDING    │ → │   UNDER     │ → │  APPROVED   │
│             │    │  (AI Call)  │    │   REVIEW    │    │   REVIEW    │    │             │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘    └──────┬──────┘
                                                                                   │
                                                           ┌─────────────┐         │
                                                           │  REJECTED   │ ←───────┤
                                                           └─────────────┘         ↓
                                                                            ┌─────────────┐
                                                                            │  COMPLETED  │
                                                                            └─────────────┘
```

**Key Issues Found & Fixed:**

| Issue | Impact | Fixed In |
|-------|--------|----------|
| TALK3 coupon missing | Users can't use promo code | SQL Migration |
| coupon_usage wrong structure | Checkout fails | SQL Migration |
| Free trial logic blocks users | No free trials work | Code Fix |
| AI draft shown before approval | Privacy violation | Code Fix |
| Commission trigger missing | Employees don't get commissions | SQL Migration |

---

## 📋 Step-by-Step Deployment

### Step 1: Run SQL Migration (5 minutes)

1. Go to **Supabase Dashboard** → **SQL Editor**
2. Copy the entire contents of `012_bulletproof_production_fixes_v2.sql`
3. Click **Run**
4. You should see verification output at the end:

```
============================================
   MIGRATION VERIFICATION REPORT
============================================

✓ TALK3 coupon exists: true
  └─ Discount percent: 100
✓ coupon_usage table exists: true
✓ credits_remaining column exists: true
✓ is_super_user column exists: true
✓ Commission trigger exists: true

============================================
   MIGRATION COMPLETE
============================================
```

5. **Verify with these queries:**

```sql
-- Check TALK3 coupon
SELECT code, discount_percent, is_active FROM employee_coupons WHERE code = 'TALK3';
-- Expected: TALK3 | 100 | true

-- Test the validate_coupon function
SELECT * FROM validate_coupon('TALK3');
-- Expected: is_valid=true, discount_percent=100, employee_id=null, is_promo_code=true
```

---

### Step 2: Apply Code Fixes (15 minutes)

Use Claude Code or manually apply these changes:

#### Fix 1: Free Trial Logic
**File:** `app/dashboard/letters/new/page.tsx`

Replace `checkSubscription` function to check letter count FIRST:
- If user has 0 letters → Allow free trial (set `hasSubscription = true`)
- If user has letters → Check subscription credits as before

#### Fix 2: Hide AI Draft Before Approval
**File:** `app/dashboard/letters/[id]/page.tsx`

Wrap letter content display in conditional:
- If status is `approved` or `completed` → Show final content
- All other statuses → Show "Content Under Review" placeholder

#### Fix 3: Environment Variable Name
**File:** `app/api/verify-payment/route.ts`

Change line 12:
```typescript
// FROM:
process.env.SERVICE_ROLE_KEY!
// TO:
process.env.SUPABASE_SERVICE_ROLE_KEY!
```

See `BULLETPROOF_CODE_FIXES_V2.md` for complete code snippets.

---

### Step 3: Verify Environment Variables in Vercel

Go to **Vercel** → **Settings** → **Environment Variables**

Ensure ALL of these are set:

```bash
# Supabase
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJ...
SUPABASE_SERVICE_ROLE_KEY=eyJ...  # ← Note: NOT "SERVICE_ROLE_KEY"

# OpenAI (for letter generation)
OPENAI_API_KEY=sk-...

# Stripe
STRIPE_SECRET_KEY=sk_live_...
STRIPE_WEBHOOK_SECRET=whsec_...
NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY=pk_live_...

# Admin Portal (CRITICAL!)
ADMIN_EMAIL=your-admin@example.com
ADMIN_PASSWORD=your-secure-password
ADMIN_PORTAL_KEY=random-secret-key

# App URL
NEXT_PUBLIC_APP_URL=https://www.talk-to-my-lawyer.com
```

⚠️ **CRITICAL:** If `ADMIN_EMAIL`, `ADMIN_PASSWORD`, or `ADMIN_PORTAL_KEY` are not set, the admin portal will return a 503 error.

---

### Step 4: Redeploy Application

```bash
# If using Git:
git add .
git commit -m "Apply bulletproof production fixes"
git push origin main
```

Or trigger a manual redeploy in Vercel Dashboard.

---

## 🧪 Testing Checklist

### Test 1: Free Trial Flow ✅

1. Create new user account (use incognito/new email)
2. Go to `/dashboard/letters`
3. Click "New Letter"
4. Fill out the form
5. Click "Generate"

**Expected:**
- ✅ Letter should generate WITHOUT needing subscription
- ✅ Status should transition: `generating` → `pending_review`
- ✅ User should see "Content Under Review" (NOT the AI draft)

---

### Test 2: TALK3 Coupon Flow ✅

1. Go to `/dashboard/subscription`
2. Select any plan (e.g., "Single Letter")
3. Enter `TALK3` in coupon field
4. Click "Apply"

**Expected:**
- ✅ Discount shows 100% ($0 total)
- ✅ Click "Subscribe Now" completes without payment
- ✅ Subscription is created with credits

**Verify in Supabase:**
```sql
SELECT * FROM subscriptions ORDER BY created_at DESC LIMIT 1;
-- Should show coupon_code='TALK3', price=0
```

---

### Test 3: Admin Review Flow ✅

1. Go to `/secure-admin-gateway/login`
2. Login with admin credentials
3. See letters in "Review Center"
4. Click on a pending letter
5. Click "Start Review"
6. Edit content and click "Approve"

**Expected:**
- ✅ Letter status changes: `pending_review` → `under_review` → `approved`
- ✅ Subscriber can now see the letter content
- ✅ Audit trail is logged

**Verify audit trail:**
```sql
SELECT action, old_status, new_status, created_at 
FROM letter_audit_trail 
WHERE letter_id = 'your-letter-id'
ORDER BY created_at;
```

---

### Test 4: Employee Commission Flow ✅

1. Create/login as employee user
2. Get employee's coupon code from `/dashboard/coupons`
3. As a different user, use that coupon code
4. Complete a subscription purchase

**Expected:**
- ✅ Commission record created automatically (5% of sale)
- ✅ Employee can see commission in `/dashboard/commissions`

**Verify commission:**
```sql
SELECT c.*, p.email as employee_email
FROM commissions c
JOIN profiles p ON c.employee_id = p.id
ORDER BY c.created_at DESC;
```

---

## 🔍 Troubleshooting

### Issue: TALK3 coupon shows "Invalid"

**Check:**
```sql
SELECT * FROM employee_coupons WHERE code = 'TALK3';
```

**If missing, run:**
```sql
INSERT INTO employee_coupons (code, discount_percent, is_active, employee_id)
VALUES ('TALK3', 100, true, NULL)
ON CONFLICT (code) DO UPDATE SET discount_percent = 100, is_active = true;
```

---

### Issue: Free trial doesn't work

**Check in browser console:**
1. Open DevTools → Network tab
2. Go to "New Letter" page
3. Look for subscription check API call
4. Verify response

**Check letter count:**
```sql
SELECT COUNT(*) FROM letters WHERE user_id = 'your-user-id';
-- If count > 0, user has already used free trial
```

---

### Issue: Admin login returns 503

**Check Vercel environment variables:**
- `ADMIN_EMAIL`
- `ADMIN_PASSWORD`
- `ADMIN_PORTAL_KEY`

All three must be set for admin portal to work.

---

### Issue: Commission not created

**Check trigger exists:**
```sql
SELECT * FROM pg_trigger WHERE tgname = 'create_commission_on_subscription';
```

**If missing, run the SQL migration again.**

---

## 📁 Files Included

| File | Description |
|------|-------------|
| `012_bulletproof_production_fixes_v2.sql` | Complete SQL migration - run in Supabase |
| `BULLETPROOF_CODE_FIXES_V2.md` | TypeScript code changes with exact snippets |
| `DEPLOYMENT_GUIDE_V2.md` | This deployment guide |

---

## 🎯 Final Verification

After deployment, run these SQL queries to confirm everything is working:

```sql
-- 1. TALK3 coupon active
SELECT code, discount_percent, is_active FROM employee_coupons WHERE code = 'TALK3';

-- 2. coupon_usage table has correct structure
SELECT column_name FROM information_schema.columns WHERE table_name = 'coupon_usage';

-- 3. Commission trigger active
SELECT tgname, tgenabled FROM pg_trigger WHERE tgname = 'create_commission_on_subscription';

-- 4. All helper functions exist
SELECT routine_name FROM information_schema.routines 
WHERE routine_schema = 'public' AND routine_type = 'FUNCTION'
AND routine_name IN ('validate_coupon', 'deduct_letter_allowance', 'is_admin', 'log_letter_audit');

-- 5. Test validate_coupon
SELECT * FROM validate_coupon('TALK3');
```

---

## ✅ You're Done!

Your Talk-to-my-Lawyer platform is now production-ready with:

- ✅ Free trial for first-time users
- ✅ TALK3 promotional coupon (100% discount)
- ✅ Proper subscription/credit tracking
- ✅ Automatic commission creation for employees
- ✅ Secure admin review workflow
- ✅ AI draft hidden until approval
- ✅ Complete audit trail

🚀 **Go live with confidence!**
