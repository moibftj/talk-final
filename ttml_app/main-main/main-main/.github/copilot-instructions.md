# Talk-To-My-Lawyer AI Agent Instructions

## Project Overview
Next.js 16 SaaS platform for AI-powered legal letter generation with mandatory attorney review. Three-role system (subscriber, employee, admin) with Supabase backend, Stripe payments, and Google Gemini AI.

## Architecture Fundamentals

### The Three-Role System
**Critical**: Every feature must respect role boundaries enforced by RLS and middleware:
- **Subscriber**: Creates letters, views own content only
- **Employee**: Manages coupons/commissions, **completely blocked from letter content** via RLS
- **Admin**: Reviews all letters with AI assistance, manages platform

### Letter Lifecycle (Core Flow)
```
generating → pending_review → under_review → completed/rejected
```
Every status change MUST be logged via `log_letter_audit()` database function. The admin review is **mandatory** - no letter reaches subscribers without admin approval.

### Key Design Principle: "AI Hidden from Users"
All user-facing text says "Attorney-Generated" or "Professional Drafting" - never mention AI/Gemini. Backend uses Gemini but this is implementation detail.

## Critical Patterns

### 1. Database Functions (Not API-Only)
Major operations use PostgreSQL functions for consistency:
- `deduct_letter_allowance(u_id)` - Handles super_user bypass, subscription checks
- `log_letter_audit()` - Records every letter state change
- `check_letter_allowance(u_id)` - Non-destructive credit check
- `reset_monthly_allowances()` - Cron job target

**Why**: RLS policies apply uniformly, audit trails are atomic, super_user logic centralized.

### 2. Free Trial Implementation
First letter is FREE without subscription. Check: `SELECT COUNT(*) FROM letters WHERE user_id = ?`. If zero, skip allowance deduction. After generation, show pricing overlay (see `FREE_TRIAL_IMPLEMENTATION.md`).

### 3. Supabase Client Pattern
- **Server components**: Use `createClient()` from `@/lib/supabase/server`
- **API routes**: Same, but explicitly handle service role operations
- **Client components**: Use `createBrowserClient()` (if exists) or fetch from API

### 4. Admin Review Modal Workflow
Located in `components/review-letter-modal.tsx`:
1. Admin clicks "Review" → status becomes `under_review`
2. Modal shows draft, editable textarea
3. "AI Improve" button calls `/api/letters/[id]/improve` with instruction
4. Approve → saves `final_content`, status = `completed`, logs audit
5. Reject → status = `rejected`, saves `rejection_reason`

## Development Commands

```bash
# Development
pnpm dev                    # Start dev server (port 3000)
pnpm build                  # Production build
pnpm lint                   # ESLint check

# Database migrations (run in order)
# Apply via Supabase SQL Editor: COMPLETE_MIGRATION.sql contains full schema
# Or use numbered scripts in supabase/migrations/

# Git workflow
npm run save                # Auto-commit + push (see AUTO_COMMIT_GUIDE.md)
```

## Common Tasks

### Adding a New API Endpoint
1. Create `app/api/[route]/route.ts`
2. Extract user with `await supabase.auth.getUser()`
3. Fetch user role: `profiles.select('role').eq('id', user.id).single()`
4. Return `NextResponse.json()` with proper status codes
5. Log errors without exposing internals

**Example**:
```typescript
export async function POST(request: Request) {
  const supabase = createClient()
  const { data: { user } } = await supabase.auth.getUser()
  if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 })
  
  const { data: profile } = await supabase.from('profiles').select('role').eq('id', user.id).single()
  if (profile?.role !== 'admin') return NextResponse.json({ error: "Forbidden" }, { status: 403 })
  
  // Implementation
}
```

### Adding a Database Table
1. Add table in `COMPLETE_MIGRATION.sql` or new migration
2. Define RLS policies with role checks using `get_user_role()`
3. Create audit trigger if status/state changes occur
4. Update TypeScript types if needed
5. Document in `DATABASE_FUNCTIONS.md` if functions added

### Modifying Letter Status Flow
1. Update enum in `COMPLETE_MIGRATION.sql` if new status
2. Add case in admin dashboard letter list
3. Call `log_letter_audit()` for every transition
4. Update `PLATFORM_ARCHITECTURE.md` flow diagram

## Environment Variables
See `.env.example` (create `.env.local` locally):
- `NEXT_PUBLIC_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_ANON_KEY` - Public keys
- `SUPABASE_SERVICE_ROLE_KEY` - Server-only, never expose to client
- `GEMINI_API_KEY` - Google AI for letter generation
- `CRON_SECRET` - Protect monthly reset endpoint
- `STRIPE_SECRET_KEY` / `STRIPE_WEBHOOK_SECRET` - Payment integration (pending)

## Security Constraints

### Never Bypass RLS
RLS policies enforce data isolation. Service role usage must be surgical:
- ✅ Use for cross-user operations (admin viewing all letters)
- ✅ Use for system functions (monthly reset)
- ❌ Never use to let employees see letter content
- ❌ Never use to skip audit logging

### API Authentication Pattern
Every API route starts with:
```typescript
const { data: { user } } = await supabase.auth.getUser()
if (!user) return NextResponse.json({ error: "Unauthorized" }, { status: 401 })
```

### Error Messages
- ❌ "Database query failed: column xyz doesn't exist"
- ✅ "Unable to process request"
- ❌ "Gemini API key invalid"
- ✅ "AI service temporarily unavailable"

## Testing Approach
No automated test suite yet. Manual QA via `MANUAL_QA_SCRIPT.md`:
1. Signup → Generate free letter → See pricing overlay
2. Admin reviews → Approves → Subscriber downloads
3. Employee creates coupon → Subscriber uses → Commission created

## Common Pitfalls

1. **Forgetting audit logs**: Every letter status change needs `log_letter_audit()`
2. **Role checks only in middleware**: Also verify server-side in API routes
3. **Exposing AI branding**: Use "Attorney" language in all user-facing text
4. **Skipping super_user checks**: Functions like `deduct_letter_allowance()` handle this
5. **Hardcoding allowances**: Use database functions, they know plan types
6. **Not deducting credits on free trial**: Check letter count first

## File Structure Highlights
- `middleware.ts` - Role-based routing, minimal (calls `lib/supabase/middleware`)
- `PLATFORM_ARCHITECTURE.md` - Complete system flow diagrams
- `DATABASE_FUNCTIONS.md` - Every function's purpose and SQL
- `GEMINI_INTEGRATION.md` - AI prompts, error handling, cost estimates
- `COMPLETE_MIGRATION.sql` - Full schema in one file (852 lines)

## Integration Points

### Gemini AI
- Endpoint: `generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent`
- Used in: `/api/generate-letter` (drafts), `/api/letters/[id]/improve` (admin refinement)
- Config: `{ temperature: 0.7, topK: 40, topP: 0.95, maxOutputTokens: 2048 }`
- Error handling: Mark letter `failed` on error, log in audit trail

### Stripe (Partially Implemented)
- Checkout: `/api/create-checkout` (skeleton exists)
- Webhook: `/api/webhooks/stripe` (needs implementation)
- Plan types: `one_time` (1 letter), `monthly_standard` (4), `monthly_premium` (12)

### Supabase Realtime (Not Implemented)
Future: Real-time dashboard updates when admin approves letters

## When You're Stuck
1. Check `PLATFORM_ARCHITECTURE.md` for flow diagrams
2. See `DATABASE_FUNCTIONS.md` for function signatures
3. Review `MASTER_PLAN_ARCHITECTURE.md` for implementation checklist
4. Query Supabase logs (Dashboard → Logs) for RLS denials
5. Check `letter_audit_trail` table for status change history

## Style Conventions
- TypeScript throughout, `ignoreBuildErrors: true` in next.config (fix gradually)
- Tailwind CSS for styling, shadcn/ui components (Radix primitives)
- Server components by default, client components only when needed
- Error responses: `NextResponse.json({ error: "message" }, { status: code })`
- Success responses: `NextResponse.json({ data: result })`

## Don't Waste Time On
- Complex auth flows - Supabase handles it
- Manual SQL joins for audit trails - functions do it
- Re-implementing allowance logic - `deduct_letter_allowance()` exists
- Custom PDF generation - implementation pending, use placeholder
- Real-time features - not in scope yet
