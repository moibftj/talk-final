-- TASK 2: Create missing coupon_usage table
-- This table tracks all coupon usage for analytics and commission tracking

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

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_coupon_usage_user ON coupon_usage(user_id);
CREATE INDEX IF NOT EXISTS idx_coupon_usage_code ON coupon_usage(coupon_code);
CREATE INDEX IF NOT EXISTS idx_coupon_usage_employee ON coupon_usage(employee_id);
CREATE INDEX IF NOT EXISTS idx_coupon_usage_created ON coupon_usage(created_at DESC);

-- Add comment for documentation
COMMENT ON TABLE coupon_usage IS 'Tracks all coupon code usage including TALK3 and employee coupons';
COMMENT ON COLUMN coupon_usage.employee_id IS 'Employee who owns the coupon, NULL for special codes like TALK3';
COMMENT ON COLUMN coupon_usage.discount_percent IS 'Percentage discount applied (0-100)';