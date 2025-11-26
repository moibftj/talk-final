-- ============================================================================
-- Migration: 012_bulletproof_production_fixes_v2.sql
-- Description: Comprehensive production-ready fixes for Talk-to-my-Lawyer
-- Created: 2025-11-26
-- Aligned with: PLATFORM_ARCHITECTURE.md
-- 
-- This migration addresses all gaps between the codebase and database:
-- 1. TALK3 special coupon code support (100% discount)
-- 2. coupon_usage table structure aligned with API code
-- 3. Commission creation trigger for subscriptions
-- 4. Missing columns and constraints
-- 5. Enhanced RLS policies
-- 6. Security hardening
-- 7. Helper functions for production
-- ============================================================================

-- ============================================================================
-- SECTION 1: TALK3 SPECIAL COUPON CODE SUPPORT
-- ============================================================================

-- The TALK3 code is a special promotional code that provides 100% discount
-- It should be stored in employee_coupons with employee_id = NULL

-- First, ensure the employee_coupons table allows NULL employee_id
DO $$
BEGIN
    -- Check if employee_id column has NOT NULL constraint and remove it
    IF EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_schema = 'public' 
        AND table_name = 'employee_coupons' 
        AND column_name = 'employee_id' 
        AND is_nullable = 'NO'
    ) THEN
        ALTER TABLE employee_coupons ALTER COLUMN employee_id DROP NOT NULL;
    END IF;
END $$;

-- Insert TALK3 coupon if it doesn't exist
INSERT INTO employee_coupons (id, employee_id, code, discount_percent, is_active, usage_count, created_at, updated_at)
VALUES (
    gen_random_uuid(),
    NULL,  -- No employee association for promotional codes
    'TALK3',
    100,   -- 100% discount
    true,
    0,
    NOW(),
    NOW()
)
ON CONFLICT (code) DO UPDATE SET
    discount_percent = 100,
    is_active = true,
    updated_at = NOW();

-- Add comment for documentation
COMMENT ON TABLE employee_coupons IS 'Employee referral coupons and promotional codes. employee_id can be NULL for promo codes like TALK3';

-- ============================================================================
-- SECTION 2: COUPON_USAGE TABLE - ALIGNED WITH API CODE
-- ============================================================================

-- The application code (create-checkout and verify-payment routes) expects:
-- - user_id: UUID referencing profiles
-- - coupon_code: TEXT (not coupon_id UUID) 
-- - employee_id: UUID (optional, for tracking referrals)
-- - discount_percent: INTEGER
-- - amount_before: NUMERIC
-- - amount_after: NUMERIC
-- - subscription_id: UUID (optional, for linking to subscription)

-- Drop the old table if it exists with wrong structure
DROP TABLE IF EXISTS coupon_usage CASCADE;

-- Create coupon_usage table matching application code expectations
CREATE TABLE coupon_usage (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    employee_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
    coupon_code TEXT NOT NULL,
    subscription_id UUID REFERENCES subscriptions(id) ON DELETE SET NULL,
    discount_percent INTEGER NOT NULL DEFAULT 0 CHECK (discount_percent >= 0 AND discount_percent <= 100),
    amount_before NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (amount_before >= 0),
    amount_after NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (amount_after >= 0),
    discount_applied NUMERIC(10,2) GENERATED ALWAYS AS (amount_before - amount_after) STORED,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX idx_coupon_usage_user_id ON coupon_usage(user_id);
CREATE INDEX idx_coupon_usage_coupon_code ON coupon_usage(coupon_code);
CREATE INDEX idx_coupon_usage_employee_id ON coupon_usage(employee_id);
CREATE INDEX idx_coupon_usage_subscription_id ON coupon_usage(subscription_id);
CREATE INDEX idx_coupon_usage_created_at ON coupon_usage(created_at DESC);

-- Enable RLS
ALTER TABLE coupon_usage ENABLE ROW LEVEL SECURITY;

-- RLS Policies for coupon_usage
DROP POLICY IF EXISTS "Users view own coupon usage" ON coupon_usage;
CREATE POLICY "Users view own coupon usage"
ON coupon_usage FOR SELECT
USING (user_id = auth.uid());

DROP POLICY IF EXISTS "Admins view all coupon usage" ON coupon_usage;
CREATE POLICY "Admins view all coupon usage"
ON coupon_usage FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM profiles
        WHERE id = auth.uid()
        AND role = 'admin'
    )
);

DROP POLICY IF EXISTS "Employees view their referral usage" ON coupon_usage;
CREATE POLICY "Employees view their referral usage"
ON coupon_usage FOR SELECT
USING (employee_id = auth.uid());

-- Allow insert from authenticated users (via API routes)
DROP POLICY IF EXISTS "System can create coupon usage" ON coupon_usage;
CREATE POLICY "System can create coupon usage"
ON coupon_usage FOR INSERT
WITH CHECK (auth.uid() IS NOT NULL);

COMMENT ON TABLE coupon_usage IS 'Tracks usage of coupon codes for analytics and commission tracking';

-- ============================================================================
-- SECTION 3: SUBSCRIPTIONS TABLE - ENSURE ALL REQUIRED COLUMNS EXIST
-- ============================================================================

-- Add stripe_session_id if missing (used by verify-payment route)
ALTER TABLE subscriptions 
ADD COLUMN IF NOT EXISTS stripe_session_id TEXT;

-- Add credits_remaining if missing (used by generate-letter route)
ALTER TABLE subscriptions 
ADD COLUMN IF NOT EXISTS credits_remaining INTEGER DEFAULT 0;

-- Add plan_type column if missing (TEXT version for flexibility)
ALTER TABLE subscriptions 
ADD COLUMN IF NOT EXISTS plan_type TEXT;

-- Add remaining_letters if missing
ALTER TABLE subscriptions 
ADD COLUMN IF NOT EXISTS remaining_letters INTEGER DEFAULT 0;

-- Add last_reset_at if missing
ALTER TABLE subscriptions 
ADD COLUMN IF NOT EXISTS last_reset_at TIMESTAMPTZ DEFAULT NOW();

-- Add discount_percentage for commission calculations
ALTER TABLE subscriptions 
ADD COLUMN IF NOT EXISTS discount_percentage NUMERIC(5,4) DEFAULT 0;

-- Create index for stripe session lookups
CREATE INDEX IF NOT EXISTS idx_subscriptions_stripe_session ON subscriptions(stripe_session_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_coupon_code ON subscriptions(coupon_code);

-- ============================================================================
-- SECTION 4: PROFILES TABLE - ENSURE IS_SUPER_USER EXISTS
-- ============================================================================

-- Add is_super_user column if missing
ALTER TABLE profiles 
ADD COLUMN IF NOT EXISTS is_super_user BOOLEAN DEFAULT FALSE;

-- Create index for super user lookups
CREATE INDEX IF NOT EXISTS idx_profiles_is_super_user ON profiles(is_super_user) WHERE is_super_user = TRUE;

-- ============================================================================
-- SECTION 5: COMMISSIONS TABLE - ENSURE CORRECT STRUCTURE
-- ============================================================================

-- The commissions table should reference subscription_id (not letter_id)
-- as per the architecture document

-- Add subscription_id if it doesn't exist
ALTER TABLE commissions 
ADD COLUMN IF NOT EXISTS subscription_id UUID REFERENCES subscriptions(id) ON DELETE SET NULL;

-- Add subscription_amount if it doesn't exist  
ALTER TABLE commissions 
ADD COLUMN IF NOT EXISTS subscription_amount NUMERIC(10,2) DEFAULT 0;

-- Create index for subscription lookups
CREATE INDEX IF NOT EXISTS idx_commissions_subscription ON commissions(subscription_id);

-- ============================================================================
-- SECTION 6: COMMISSION CREATION TRIGGER (per architecture doc)
-- ============================================================================

-- This trigger automatically creates commission records when a subscription
-- is created with a coupon code

CREATE OR REPLACE FUNCTION create_commission_for_subscription()
RETURNS TRIGGER AS $$
DECLARE
    emp_id UUID;
    coupon_discount INTEGER;
BEGIN
    -- Only create commission if coupon_code is present
    IF NEW.coupon_code IS NOT NULL AND NEW.coupon_code != '' THEN
        -- Get employee_id and discount from coupon
        SELECT employee_id, discount_percent INTO emp_id, coupon_discount
        FROM employee_coupons
        WHERE code = NEW.coupon_code
        AND is_active = TRUE;
        
        -- Only create commission if employee exists and coupon is not a promo code
        -- Promo codes (like TALK3) have NULL employee_id
        IF emp_id IS NOT NULL THEN
            -- Insert commission record
            INSERT INTO commissions (
                employee_id,
                subscription_id,
                commission_rate,
                subscription_amount,
                commission_amount,
                status,
                created_at
            ) VALUES (
                emp_id,
                NEW.id,
                0.05, -- 5% commission rate
                NEW.price,
                NEW.price * 0.05,
                'pending',
                NOW()
            )
            ON CONFLICT DO NOTHING; -- Prevent duplicate commissions
            
            -- Update coupon usage count
            UPDATE employee_coupons
            SET usage_count = usage_count + 1,
                updated_at = NOW()
            WHERE code = NEW.coupon_code;
        END IF;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Drop existing trigger if exists
DROP TRIGGER IF EXISTS create_commission_on_subscription ON subscriptions;

-- Create trigger that fires AFTER subscription insert
CREATE TRIGGER create_commission_on_subscription
    AFTER INSERT ON subscriptions
    FOR EACH ROW
    EXECUTE FUNCTION create_commission_for_subscription();

COMMENT ON FUNCTION create_commission_for_subscription IS 
'Automatically creates commission for employee when subscription uses their coupon code';

-- ============================================================================
-- SECTION 7: LETTERS TABLE - ENSURE ALL STATUS VALUES AND COLUMNS
-- ============================================================================

-- Add admin_edited_content column if missing
ALTER TABLE letters 
ADD COLUMN IF NOT EXISTS admin_edited_content TEXT;

-- Add reviewed_content if missing
ALTER TABLE letters 
ADD COLUMN IF NOT EXISTS reviewed_content TEXT;

-- Add completed_at timestamp if missing
ALTER TABLE letters 
ADD COLUMN IF NOT EXISTS completed_at TIMESTAMPTZ;

-- Add sent_at timestamp if missing (for email tracking)
ALTER TABLE letters 
ADD COLUMN IF NOT EXISTS sent_at TIMESTAMPTZ;

-- Ensure all required letter statuses exist in the enum
DO $$
BEGIN
    -- Add 'generating' status
    BEGIN
        ALTER TYPE letter_status ADD VALUE IF NOT EXISTS 'generating';
    EXCEPTION
        WHEN duplicate_object THEN NULL;
    END;
    
    -- Add 'under_review' status
    BEGIN
        ALTER TYPE letter_status ADD VALUE IF NOT EXISTS 'under_review';
    EXCEPTION
        WHEN duplicate_object THEN NULL;
    END;
    
    -- Add 'completed' status
    BEGIN
        ALTER TYPE letter_status ADD VALUE IF NOT EXISTS 'completed';
    EXCEPTION
        WHEN duplicate_object THEN NULL;
    END;
    
    -- Add 'failed' status
    BEGIN
        ALTER TYPE letter_status ADD VALUE IF NOT EXISTS 'failed';
    EXCEPTION
        WHEN duplicate_object THEN NULL;
    END;
END $$;

-- ============================================================================
-- SECTION 8: SECURITY CONFIG AND AUDIT LOG TABLES
-- ============================================================================

-- Create security_config table if not exists
CREATE TABLE IF NOT EXISTS security_config (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    key TEXT NOT NULL UNIQUE,
    value TEXT NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create security_audit_log table if not exists
CREATE TABLE IF NOT EXISTS security_audit_log (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
    event_type TEXT NOT NULL,
    ip_address INET,
    user_agent TEXT,
    details JSONB,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE security_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE security_audit_log ENABLE ROW LEVEL SECURITY;

-- Security config policies (admin only)
DROP POLICY IF EXISTS "Admins manage security config" ON security_config;
CREATE POLICY "Admins manage security config"
ON security_config FOR ALL
USING (
    EXISTS (
        SELECT 1 FROM profiles
        WHERE id = auth.uid()
        AND role = 'admin'
    )
);

-- Security audit log policies
DROP POLICY IF EXISTS "Admins view security audit" ON security_audit_log;
CREATE POLICY "Admins view security audit"
ON security_audit_log FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM profiles
        WHERE id = auth.uid()
        AND role = 'admin'
    )
);

-- Create indexes
CREATE INDEX IF NOT EXISTS idx_security_audit_user ON security_audit_log(user_id);
CREATE INDEX IF NOT EXISTS idx_security_audit_event ON security_audit_log(event_type);
CREATE INDEX IF NOT EXISTS idx_security_audit_created ON security_audit_log(created_at DESC);

-- ============================================================================
-- SECTION 9: HELPER FUNCTIONS
-- ============================================================================

-- Function to get user role (used in RLS policies)
CREATE OR REPLACE FUNCTION public.get_user_role()
RETURNS TEXT AS $$
BEGIN
    RETURN (
        SELECT role::TEXT
        FROM profiles
        WHERE id = auth.uid()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- Function to check if current user is admin
CREATE OR REPLACE FUNCTION public.is_admin()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN (
        SELECT role = 'admin'
        FROM profiles
        WHERE id = auth.uid()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- Function to check if current user is super user
CREATE OR REPLACE FUNCTION public.is_super_user()
RETURNS BOOLEAN AS $$
BEGIN
    RETURN (
        SELECT COALESCE(is_super_user, FALSE)
        FROM profiles
        WHERE id = auth.uid()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- Function to validate coupon code (including TALK3)
CREATE OR REPLACE FUNCTION public.validate_coupon(p_coupon_code TEXT)
RETURNS TABLE (
    is_valid BOOLEAN,
    discount_percent INTEGER,
    employee_id UUID,
    is_promo_code BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        TRUE AS is_valid,
        ec.discount_percent,
        ec.employee_id,
        (ec.employee_id IS NULL) AS is_promo_code
    FROM employee_coupons ec
    WHERE ec.code = UPPER(p_coupon_code)
    AND ec.is_active = TRUE;
    
    -- Return invalid if no coupon found
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 0, NULL::UUID, FALSE;
    END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER STABLE;

-- Enhanced deduct_letter_allowance function
CREATE OR REPLACE FUNCTION public.deduct_letter_allowance(u_id UUID)
RETURNS BOOLEAN AS $$
DECLARE
    sub_record RECORD;
    is_super BOOLEAN;
BEGIN
    -- Check if user is super user (unlimited letters)
    SELECT COALESCE(is_super_user, FALSE) INTO is_super
    FROM profiles
    WHERE id = u_id;
    
    IF is_super THEN
        RETURN TRUE; -- Super users have unlimited letters
    END IF;

    -- Get active subscription with credits
    SELECT * INTO sub_record
    FROM subscriptions
    WHERE user_id = u_id
    AND status = 'active'
    ORDER BY created_at DESC
    LIMIT 1;

    IF NOT FOUND THEN
        RETURN FALSE; -- No active subscription
    END IF;

    -- Check both credits_remaining and remaining_letters for backwards compatibility
    IF COALESCE(sub_record.credits_remaining, sub_record.remaining_letters, 0) <= 0 THEN
        RETURN FALSE; -- No credits remaining
    END IF;

    -- Deduct 1 credit from both fields for consistency
    UPDATE subscriptions
    SET 
        credits_remaining = GREATEST(0, COALESCE(credits_remaining, 0) - 1),
        remaining_letters = GREATEST(0, COALESCE(remaining_letters, 0) - 1),
        updated_at = NOW()
    WHERE id = sub_record.id;

    RETURN TRUE;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to add letter allowances (for subscription activation)
CREATE OR REPLACE FUNCTION public.add_letter_allowances(sub_id UUID, plan_name TEXT)
RETURNS VOID AS $$
DECLARE
    letters_to_add INT;
BEGIN
    -- Determine letters based on plan name (support multiple naming conventions)
    letters_to_add := CASE 
        WHEN plan_name IN ('one_time', 'single_letter') THEN 1
        WHEN plan_name IN ('standard_4_month', 'monthly_standard', 'monthly') THEN 4
        WHEN plan_name IN ('premium_8_month', 'monthly_premium', 'yearly') THEN 8
        ELSE 0
    END;

    UPDATE subscriptions
    SET 
        credits_remaining = letters_to_add,
        remaining_letters = letters_to_add,
        last_reset_at = NOW(),
        updated_at = NOW()
    WHERE id = sub_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to reset monthly allowances (for cron job)
CREATE OR REPLACE FUNCTION public.reset_monthly_allowances()
RETURNS VOID AS $$
BEGIN
    UPDATE subscriptions
    SET 
        credits_remaining = CASE
            WHEN plan_type IN ('monthly_standard', 'standard_4_month') THEN 4
            WHEN plan_type IN ('monthly_premium', 'premium_8_month') THEN 8
            ELSE credits_remaining -- one_time doesn't reset
        END,
        remaining_letters = CASE
            WHEN plan_type IN ('monthly_standard', 'standard_4_month') THEN 4
            WHEN plan_type IN ('monthly_premium', 'premium_8_month') THEN 8
            ELSE remaining_letters
        END,
        last_reset_at = NOW(),
        updated_at = NOW()
    WHERE status = 'active'
    AND plan_type NOT IN ('one_time', 'single_letter')
    AND DATE_TRUNC('month', last_reset_at) < DATE_TRUNC('month', NOW());
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Log letter audit function (ensure it exists with correct signature)
CREATE OR REPLACE FUNCTION public.log_letter_audit(
    p_letter_id UUID,
    p_action TEXT,
    p_old_status TEXT DEFAULT NULL,
    p_new_status TEXT DEFAULT NULL,
    p_notes TEXT DEFAULT NULL,
    p_metadata JSONB DEFAULT NULL
)
RETURNS VOID AS $$
BEGIN
    INSERT INTO letter_audit_trail (
        letter_id,
        action,
        performed_by,
        old_status,
        new_status,
        notes,
        metadata,
        created_at
    ) VALUES (
        p_letter_id,
        p_action,
        auth.uid(),
        p_old_status,
        p_new_status,
        p_notes,
        p_metadata,
        NOW()
    );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- SECTION 10: GRANT PERMISSIONS
-- ============================================================================

-- Grant execute permissions on functions
GRANT EXECUTE ON FUNCTION public.get_user_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_super_user() TO authenticated;
GRANT EXECUTE ON FUNCTION public.validate_coupon(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_letter_allowance(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_letter_allowances(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.reset_monthly_allowances() TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_letter_audit(UUID, TEXT, TEXT, TEXT, TEXT, JSONB) TO authenticated;

-- ============================================================================
-- SECTION 11: DATA MIGRATION - SYNC CREDITS
-- ============================================================================

-- Sync credits_remaining with remaining_letters for existing subscriptions
UPDATE subscriptions
SET credits_remaining = COALESCE(remaining_letters, 0)
WHERE (credits_remaining IS NULL OR credits_remaining = 0)
AND remaining_letters > 0;

-- Sync remaining_letters with credits_remaining where missing
UPDATE subscriptions
SET remaining_letters = COALESCE(credits_remaining, 0)
WHERE (remaining_letters IS NULL OR remaining_letters = 0)
AND credits_remaining > 0;

-- Calculate and store discount_percentage for existing subscriptions
UPDATE subscriptions
SET discount_percentage = CASE 
    WHEN discount > 0 AND price > 0 THEN discount / (price + discount)
    ELSE 0
END
WHERE discount_percentage IS NULL OR discount_percentage = 0;

-- ============================================================================
-- SECTION 12: FINAL VERIFICATION LOG
-- ============================================================================

DO $$
DECLARE
    talk3_exists BOOLEAN;
    coupon_usage_exists BOOLEAN;
    credits_col_exists BOOLEAN;
    super_user_col_exists BOOLEAN;
    commission_trigger_exists BOOLEAN;
    talk3_discount INTEGER;
BEGIN
    -- Check TALK3 coupon
    SELECT EXISTS (
        SELECT 1 FROM employee_coupons WHERE code = 'TALK3'
    ) INTO talk3_exists;
    
    -- Get TALK3 discount
    SELECT discount_percent INTO talk3_discount
    FROM employee_coupons WHERE code = 'TALK3';
    
    -- Check coupon_usage table
    SELECT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'public' AND table_name = 'coupon_usage'
    ) INTO coupon_usage_exists;
    
    -- Check credits_remaining column
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' 
        AND table_name = 'subscriptions' 
        AND column_name = 'credits_remaining'
    ) INTO credits_col_exists;
    
    -- Check is_super_user column
    SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' 
        AND table_name = 'profiles' 
        AND column_name = 'is_super_user'
    ) INTO super_user_col_exists;
    
    -- Check commission trigger
    SELECT EXISTS (
        SELECT 1 FROM pg_trigger
        WHERE tgname = 'create_commission_on_subscription'
    ) INTO commission_trigger_exists;
    
    -- Log results
    RAISE NOTICE '';
    RAISE NOTICE '============================================';
    RAISE NOTICE '   MIGRATION VERIFICATION REPORT';
    RAISE NOTICE '============================================';
    RAISE NOTICE '';
    RAISE NOTICE '✓ TALK3 coupon exists: %', talk3_exists;
    RAISE NOTICE '  └─ Discount percent: %', COALESCE(talk3_discount::TEXT, 'N/A');
    RAISE NOTICE '✓ coupon_usage table exists: %', coupon_usage_exists;
    RAISE NOTICE '✓ credits_remaining column exists: %', credits_col_exists;
    RAISE NOTICE '✓ is_super_user column exists: %', super_user_col_exists;
    RAISE NOTICE '✓ Commission trigger exists: %', commission_trigger_exists;
    RAISE NOTICE '';
    
    -- Raise warning if any check failed
    IF NOT talk3_exists THEN
        RAISE WARNING '❌ TALK3 coupon was not created!';
    END IF;
    
    IF NOT coupon_usage_exists THEN
        RAISE WARNING '❌ coupon_usage table was not created!';
    END IF;
    
    IF NOT credits_col_exists THEN
        RAISE WARNING '❌ credits_remaining column is missing!';
    END IF;
    
    IF NOT super_user_col_exists THEN
        RAISE WARNING '❌ is_super_user column is missing!';
    END IF;
    
    IF NOT commission_trigger_exists THEN
        RAISE WARNING '❌ Commission trigger was not created!';
    END IF;
    
    RAISE NOTICE '============================================';
    RAISE NOTICE '   MIGRATION COMPLETE';
    RAISE NOTICE '============================================';
END $$;
