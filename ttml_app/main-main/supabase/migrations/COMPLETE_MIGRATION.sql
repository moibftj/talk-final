-- ============================================================================
-- COMPLETE MIGRATION FOR TALK-TO-MY-LAWYER
-- ============================================================================
-- This file combines all migrations in the correct order for easy deployment
-- Run this on a fresh Supabase database to set up the complete schema
-- ============================================================================

-- TASK 9: Complete migration file combining all migrations

-- ============================================================================
-- 001: SETUP SCHEMA
-- ============================================================================

-- Enable extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Create ENUM types for type safety
DO $$ BEGIN
    CREATE TYPE user_role AS ENUM ('subscriber', 'employee', 'admin');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE letter_status AS ENUM (
        'draft', 
        'generating', 
        'pending_review', 
        'under_review', 
        'approved', 
        'rejected', 
        'completed', 
        'failed'
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE subscription_status AS ENUM ('active', 'canceled', 'past_due');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE commission_status AS ENUM ('pending', 'paid');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Create profiles table
CREATE TABLE IF NOT EXISTS profiles (
    id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email TEXT NOT NULL UNIQUE,
    full_name TEXT,
    role user_role DEFAULT 'subscriber',
    phone TEXT,
    company_name TEXT,
    is_super_user BOOLEAN DEFAULT false,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create employee_coupons table
CREATE TABLE IF NOT EXISTS employee_coupons (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    employee_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    code TEXT NOT NULL UNIQUE,
    discount_percent INT CHECK (discount_percent BETWEEN 0 AND 100) DEFAULT 20,
    is_active BOOLEAN DEFAULT true,
    usage_count INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create subscriptions table
CREATE TABLE IF NOT EXISTS subscriptions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    status subscription_status DEFAULT 'active',
    coupon_code TEXT,
    plan TEXT DEFAULT 'single_letter',
    plan_type TEXT,
    price NUMERIC(10,2) DEFAULT 299.00,
    discount NUMERIC(10,2) DEFAULT 0.00,
    stripe_subscription_id TEXT,
    remaining_letters INT DEFAULT 0,
    credits_remaining INT DEFAULT 0,
    last_reset_at TIMESTAMPTZ,
    current_period_start TIMESTAMPTZ,
    current_period_end TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create commissions table
CREATE TABLE IF NOT EXISTS commissions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    employee_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    subscription_id UUID NOT NULL REFERENCES subscriptions(id) ON DELETE CASCADE,
    commission_rate NUMERIC(5,4) DEFAULT 0.05,
    subscription_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
    commission_amount NUMERIC(10,2) NOT NULL DEFAULT 0,
    status commission_status DEFAULT 'pending',
    paid_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create letters table
CREATE TABLE IF NOT EXISTS letters (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    title TEXT NOT NULL,
    status letter_status DEFAULT 'draft',
    letter_type TEXT,
    intake_data JSONB DEFAULT '{}',
    ai_draft_content TEXT,
    final_content TEXT,
    reviewed_by UUID REFERENCES profiles(id),
    reviewed_at TIMESTAMPTZ,
    review_notes TEXT,
    rejection_reason TEXT,
    approved_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create coupon_usage table (TASK 2)
CREATE TABLE IF NOT EXISTS coupon_usage (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
    coupon_code TEXT NOT NULL,
    employee_id UUID REFERENCES profiles(id) ON DELETE SET NULL,
    discount_percent INT CHECK (discount_percent BETWEEN 0 AND 100),
    amount_before NUMERIC(10,2) NOT NULL,
    amount_after NUMERIC(10,2) NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create letter_audit_trail table
CREATE TABLE IF NOT EXISTS letter_audit_trail (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    letter_id UUID NOT NULL REFERENCES letters(id) ON DELETE CASCADE,
    action TEXT NOT NULL,
    old_status TEXT,
    new_status TEXT,
    performed_by UUID REFERENCES profiles(id),
    notes TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_profiles_role ON profiles(role);
CREATE INDEX IF NOT EXISTS idx_profiles_email ON profiles(email);
CREATE INDEX IF NOT EXISTS idx_employee_coupons_code ON employee_coupons(code);
CREATE INDEX IF NOT EXISTS idx_employee_coupons_employee ON employee_coupons(employee_id);
CREATE INDEX IF NOT EXISTS idx_letters_user_id ON letters(user_id);
CREATE INDEX IF NOT EXISTS idx_letters_status ON letters(status);
CREATE INDEX IF NOT EXISTS idx_commissions_employee ON commissions(employee_id);
CREATE INDEX IF NOT EXISTS idx_subscriptions_user ON subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_coupon_usage_user ON coupon_usage(user_id);
CREATE INDEX IF NOT EXISTS idx_coupon_usage_code ON coupon_usage(coupon_code);
CREATE INDEX IF NOT EXISTS idx_coupon_usage_employee ON coupon_usage(employee_id);
CREATE INDEX IF NOT EXISTS idx_letter_audit_letter ON letter_audit_trail(letter_id);

-- ============================================================================
-- 002: SETUP RLS POLICIES
-- ============================================================================

-- Enable RLS on all tables
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE employee_coupons ENABLE ROW LEVEL SECURITY;
ALTER TABLE subscriptions ENABLE ROW LEVEL SECURITY;
ALTER TABLE commissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE letters ENABLE ROW LEVEL SECURITY;
ALTER TABLE coupon_usage ENABLE ROW LEVEL SECURITY;
ALTER TABLE letter_audit_trail ENABLE ROW LEVEL SECURITY;

-- Helper function to get user role
CREATE OR REPLACE FUNCTION get_user_role(user_id UUID)
RETURNS TEXT AS $$
  SELECT role::TEXT FROM profiles WHERE id = user_id;
$$ LANGUAGE SQL STABLE SECURITY DEFINER;

-- Profiles policies
CREATE POLICY "Users can view own profile" ON profiles FOR SELECT USING (auth.uid() = id);
CREATE POLICY "Users can update own profile" ON profiles FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "Admins can view all profiles" ON profiles FOR SELECT USING (get_user_role(auth.uid()) = 'admin');

-- Letters policies
CREATE POLICY "Users can view own letters" ON letters FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own letters" ON letters FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own letters" ON letters FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Admins can view all letters" ON letters FOR SELECT USING (get_user_role(auth.uid()) = 'admin');
CREATE POLICY "Admins can update all letters" ON letters FOR UPDATE USING (get_user_role(auth.uid()) = 'admin');

-- Subscriptions policies
CREATE POLICY "Users can view own subscriptions" ON subscriptions FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Admins can view all subscriptions" ON subscriptions FOR SELECT USING (get_user_role(auth.uid()) = 'admin');

-- Employee coupons policies
CREATE POLICY "Employees can view own coupons" ON employee_coupons FOR SELECT USING (auth.uid() = employee_id);
CREATE POLICY "Anyone can check coupon validity" ON employee_coupons FOR SELECT USING (true);
CREATE POLICY "Admins can manage all coupons" ON employee_coupons FOR ALL USING (get_user_role(auth.uid()) = 'admin');

-- Commissions policies
CREATE POLICY "Employees can view own commissions" ON commissions FOR SELECT USING (auth.uid() = employee_id);
CREATE POLICY "Admins can view all commissions" ON commissions FOR SELECT USING (get_user_role(auth.uid()) = 'admin');

-- Coupon usage policies
CREATE POLICY "Users can view own coupon usage" ON coupon_usage FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Admins can view all coupon usage" ON coupon_usage FOR SELECT USING (get_user_role(auth.uid()) = 'admin');

-- Audit trail policies
CREATE POLICY "Users can view audit for own letters" ON letter_audit_trail FOR SELECT 
  USING (EXISTS (SELECT 1 FROM letters WHERE letters.id = letter_audit_trail.letter_id AND letters.user_id = auth.uid()));
CREATE POLICY "Admins can view all audit trails" ON letter_audit_trail FOR SELECT USING (get_user_role(auth.uid()) = 'admin');

-- ============================================================================
-- 004: CREATE FUNCTIONS
-- ============================================================================

-- Function to check letter allowance
CREATE OR REPLACE FUNCTION check_letter_allowance(u_id UUID)
RETURNS TABLE (
  has_allowance BOOLEAN,
  remaining INT,
  plan_name TEXT,
  is_super BOOLEAN
) AS $$
DECLARE
  v_is_super BOOLEAN;
  v_remaining INT;
  v_plan TEXT;
BEGIN
  -- Check if user is super user
  SELECT is_super_user INTO v_is_super FROM profiles WHERE id = u_id;
  
  IF v_is_super THEN
    RETURN QUERY SELECT true, 999999, 'Super User'::TEXT, true;
    RETURN;
  END IF;
  
  -- Check active subscription
  SELECT 
    COALESCE(credits_remaining, 0),
    COALESCE(plan, 'None')
  INTO v_remaining, v_plan
  FROM subscriptions
  WHERE user_id = u_id AND status = 'active'
  ORDER BY created_at DESC
  LIMIT 1;
  
  IF v_remaining > 0 THEN
    RETURN QUERY SELECT true, v_remaining, v_plan, false;
  ELSE
    RETURN QUERY SELECT false, 0, COALESCE(v_plan, 'None'::TEXT), false;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Function to log audit trail
CREATE OR REPLACE FUNCTION log_letter_audit(
  p_letter_id UUID,
  p_action TEXT,
  p_old_status TEXT DEFAULT NULL,
  p_new_status TEXT DEFAULT NULL,
  p_notes TEXT DEFAULT NULL
)
RETURNS UUID AS $$
DECLARE
  v_audit_id UUID;
BEGIN
  INSERT INTO letter_audit_trail (
    letter_id,
    action,
    old_status,
    new_status,
    performed_by,
    notes
  ) VALUES (
    p_letter_id,
    p_action,
    p_old_status,
    p_new_status,
    auth.uid(),
    p_notes
  ) RETURNING id INTO v_audit_id;
  
  RETURN v_audit_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================================================
-- TRIGGERS
-- ============================================================================

-- Trigger to auto-create profile on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
    INSERT INTO public.profiles (id, email, full_name)
    VALUES (NEW.id, NEW.email, NEW.raw_user_meta_data->>'full_name');
    RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ============================================================================
-- COMMENTS
-- ============================================================================

COMMENT ON TABLE coupon_usage IS 'Tracks all coupon code usage including TALK3 and employee coupons';
COMMENT ON COLUMN coupon_usage.employee_id IS 'Employee who owns the coupon, NULL for special codes like TALK3';
COMMENT ON COLUMN coupon_usage.discount_percent IS 'Percentage discount applied (0-100)';
COMMENT ON COLUMN profiles.is_super_user IS 'Business flag for unlimited letter allowances, NOT an admin role';

-- ============================================================================
-- COMPLETION
-- ============================================================================

-- Migration complete
SELECT 'Talk-To-My-Lawyer database schema setup complete!' as status;