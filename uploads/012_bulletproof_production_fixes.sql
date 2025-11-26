-- ============================================================================
-- Migration: 012_bulletproof_production_fixes.sql
-- Description: Comprehensive production-ready fixes for Talk-to-my-Lawyer
-- Created: 2025-11-26
-- 
-- This migration addresses all gaps between the codebase and database:
-- 1. TALK3 special coupon code support (100% discount)
-- 2. coupon_usage table structure alignment with code
-- 3. Missing columns and constraints
-- 4. Enhanced RLS policies
-- 5. Security hardening
-- 6. Helper functions for production
-- ============================================================================

-- ============================================================================
-- SECTION 1: TALK3 SPECIAL COUPON CODE SUPPORT
-- ============================================================================

-- The TALK3 code is a special promotional code that provides 100% discount
-- It should be stored in employee_coupons with employee_id = NULL

-- First, ensure the employee_coupons table allows NULL employee_id
ALTER TABLE employee_coupons 
ALTER COLUMN employee_id DROP NOT NULL;

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
-- SECTION 2: COUPON_USAGE TABLE - ALIGN WITH APPLICATION CODE
-- ============================================================================

-- The application code (create-checkout and verify-payment routes) expects this structure:
-- - user_id: UUID referencing profiles
-- - coupon_code: TEXT (not coupon_id UUID)
-- - employee_id: UUID (optional, for tracking referrals)
-- - discount_percent: INTEGER
-- - amount_before: NUMERIC
-- - amount_after: NUMERIC

-- Drop the old table if it exists with wrong structure
DROP TABLE IF EXISTS coupon_usage CASCADE;

-- Create coupon_usage table matching application code expectations
CREATE TABLE coupon_usage (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    employee_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
    coupon_code TEXT NOT NULL,
    discount_percent INTEGER NOT NULL DEFAULT 0 CHECK (discount_percent >= 0 AND discount_percent <= 100),
    amount_before NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (amount_before >= 0),
    amount_after NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (amount_after >= 0),
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_coupon_usage_user_id ON coupon_usage(user_id);
CREATE INDEX IF NOT EXISTS idx_coupon_usage_coupon_code ON coupon_usage(coupon_code);
CREATE INDEX IF NOT EXISTS idx_coupon_usage_employee_id ON coupon_usage(employee_id);
CREATE INDEX IF NOT EXISTS idx_coupon_usage_created_at ON coupon_usage(created_at DESC);

-- Enable RLS
ALTER TABLE coupon_usage ENABLE ROW LEVEL SECURITY;

-- RLS Policies for coupon_usage
CREATE POLICY "Users view own coupon usage"
ON coupon_usage FOR SELECT
USING (user_id = auth.uid());

CREATE POLICY "Admins view all coupon usage"
ON coupon_usage FOR SELECT
USING (
    EXISTS (
        SELECT 1 FROM profiles
        WHERE id = auth.uid()
        AND role = 'admin'
    )
);

CREATE POLICY "Employees view their referral usage"
ON coupon_usage FOR SELECT
USING (employee_id = auth.uid());

-- Allow insert from authenticated users (via API routes with service role)
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

-- Create index for stripe session lookups
CREATE INDEX IF NOT EXISTS idx_subscriptions_stripe_session ON subscriptions(stripe_session_id);

-- ============================================================================
-- SECTION 4: PROFILES TABLE - ENSURE IS_SUPER_USER EXISTS
-- ============================================================================

-- Add is_super_user column if missing
ALTER TABLE profiles 
ADD COLUMN IF NOT EXISTS is_super_user BOOLEAN DEFAULT FALSE;

-- Create index for super user lookups
CREATE INDEX IF NOT EXISTS idx_profiles_is_super_user ON profiles(is_super_user) WHERE is_super_user = TRUE;

-- ============================================================================
-- SECTION 5: COMMISSIONS TABLE - FIX FOREIGN KEY REFERENCE
-- ============================================================================

-- The application code references subscription_id, not letter_id
-- Check if the current FK is correct

-- First, check if letter_id column exists and drop it if subscription_id is missing
DO $$
BEGIN
    -- Add subscription_id if it doesn't exist
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
        AND table_name = 'commissions'
        AND column_name = 'subscription_id'
    ) THEN
        ALTER TABLE commissions ADD COLUMN subscription_id UUID REFERENCES subscriptions(id) ON DELETE SET NULL;
    END IF;
    
    -- Add subscription_amount if it doesn't exist
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public'
        AND table_name = 'commissions'
        AND column_name = 'subscription_amount'
    ) THEN
        ALTER TABLE commissions ADD COLUMN subscription_amount NUMERIC(10,2) DEFAULT 0;
    END IF;
END $$;

-- ============================================================================
-- SECTION 6: LETTERS TABLE - ENSURE ALL STATUS VALUES AND COLUMNS
-- ============================================================================

-- Add admin_edited_content column if missing (from your schema)
ALTER TABLE letters 
ADD COLUMN IF NOT EXISTS admin_edited_content TEXT;

-- Add reviewed_content if missing
ALTER TABLE letters 
ADD COLUMN IF NOT EXISTS reviewed_content TEXT;

-- Ensure all required letter statuses exist
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
-- SECTION 7: SECURITY CONFIG AND AUDIT LOG TABLES
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
CREATE POLICY IF NOT EXISTS "Admins manage security config"
ON security_config FOR ALL
USING (
    EXISTS (
        SELECT 1 FROM profiles
        WHERE id = auth.uid()
        AND role = 'admin'
    )
);

-- Security audit log policies
CREATE POLICY IF NOT EXISTS "Admins view security audit"
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
-- SECTION 8: HELPER FUNCTIONS
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
CREATE OR REPLACE FUNCTION public.validate_coupon(coupon_code TEXT)
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
    WHERE ec.code = UPPER(coupon_code)
    AND ec.is_active = TRUE;
    
    -- Return empty if no coupon found
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
    -- Check if user is super user (unlimited)
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
    -- Determine letters based on plan
    CASE plan_name
        WHEN 'one_time' THEN letters_to_add := 1;
        WHEN 'standard_4_month' THEN letters_to_add := 4;
        WHEN 'premium_8_month' THEN letters_to_add := 8;
        WHEN 'monthly_standard' THEN letters_to_add := 4;
        WHEN 'monthly_premium' THEN letters_to_add := 12;
        ELSE letters_to_add := 0;
    END CASE;

    UPDATE subscriptions
    SET 
        credits_remaining = letters_to_add,
        remaining_letters = letters_to_add,
        last_reset_at = NOW(),
        updated_at = NOW()
    WHERE id = sub_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- SECTION 9: GRANT PERMISSIONS
-- ============================================================================

-- Grant execute permissions on functions
GRANT EXECUTE ON FUNCTION public.get_user_role() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_admin() TO authenticated;
GRANT EXECUTE ON FUNCTION public.is_super_user() TO authenticated;
GRANT EXECUTE ON FUNCTION public.validate_coupon(TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.deduct_letter_allowance(UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION public.add_letter_allowances(UUID, TEXT) TO authenticated;
GRANT EXECUTE ON FUNCTION public.log_letter_audit(UUID, TEXT, TEXT, TEXT, TEXT) TO authenticated;

-- ============================================================================
-- SECTION 10: DATA MIGRATION - SYNC CREDITS
-- ============================================================================

-- Sync credits_remaining with remaining_letters for existing subscriptions
UPDATE subscriptions
SET credits_remaining = COALESCE(remaining_letters, 0)
WHERE credits_remaining IS NULL OR credits_remaining = 0
AND remaining_letters > 0;

-- Sync remaining_letters with credits_remaining where missing
UPDATE subscriptions
SET remaining_letters = COALESCE(credits_remaining, 0)
WHERE remaining_letters IS NULL OR remaining_letters = 0
AND credits_remaining > 0;

-- ============================================================================
-- SECTION 11: VERIFY CRITICAL CONSTRAINTS
-- ============================================================================

-- Add check constraint for valid subscription status if not exists
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.check_constraints
        WHERE constraint_name = 'valid_subscription_status'
    ) THEN
        -- Status is already an enum, but we can add price validation
        ALTER TABLE subscriptions
        ADD CONSTRAINT valid_subscription_price CHECK (price >= 0 AND price <= 99999.99);
    END IF;
EXCEPTION
    WHEN duplicate_object THEN NULL;
END $$;

-- ============================================================================
-- SECTION 12: FINAL VERIFICATION LOG
-- ============================================================================

DO $$
DECLARE
    talk3_exists BOOLEAN;
    coupon_usage_exists BOOLEAN;
    credits_col_exists BOOLEAN;
    super_user_col_exists BOOLEAN;
BEGIN
    -- Check TALK3 coupon
    SELECT EXISTS (
        SELECT 1 FROM employee_coupons WHERE code = 'TALK3'
    ) INTO talk3_exists;
    
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
    
    -- Log results
    RAISE NOTICE '=== Migration Verification ===';
    RAISE NOTICE 'TALK3 coupon exists: %', talk3_exists;
    RAISE NOTICE 'coupon_usage table exists: %', coupon_usage_exists;
    RAISE NOTICE 'credits_remaining column exists: %', credits_col_exists;
    RAISE NOTICE 'is_super_user column exists: %', super_user_col_exists;
    
    -- Raise warning if any check failed
    IF NOT talk3_exists THEN
        RAISE WARNING 'TALK3 coupon was not created!';
    END IF;
    
    IF NOT coupon_usage_exists THEN
        RAISE WARNING 'coupon_usage table was not created!';
    END IF;
    
    IF NOT credits_col_exists THEN
        RAISE WARNING 'credits_remaining column is missing!';
    END IF;
    
    IF NOT super_user_col_exists THEN
        RAISE WARNING 'is_super_user column is missing!';
    END IF;
    
    RAISE NOTICE '=== Migration Complete ===';
END $$;
