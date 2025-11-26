export type UserRole = 'subscriber' | 'employee' | 'admin'
export type LetterStatus =
  | 'draft'
  | 'generating'
  | 'pending_review'
  | 'under_review'
  | 'approved'
  | 'completed'
  | 'rejected'
  | 'failed'
export type SubscriptionStatus = 'active' | 'canceled' | 'past_due'
export type CommissionStatus = 'pending' | 'paid'

export interface Profile {
  id: string
  email: string
  full_name: string | null
  role: UserRole
  is_super_user: boolean
  phone: string | null
  company_name: string | null
  avatar_url: string | null
  bio: string | null
  created_at: string
  updated_at: string
}

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
  admin_edited_content: string | null
  final_content: string | null
  reviewed_content: string | null
  reviewed_by: string | null
  reviewed_at: string | null
  review_notes: string | null
  rejection_reason: string | null
  approved_at: string | null
  completed_at: string | null
  sent_at: string | null
  created_at: string
  updated_at: string
  notes: string | null
}

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

export interface EmployeeCoupon {
  id: string
  employee_id: string
  code: string
  discount_percent: number
  is_active: boolean
  usage_count: number
  created_at: string
  updated_at: string
}

export interface Commission {
  id: string
  user_id: string
  employee_id: string
  subscription_id: string
  subscription_amount: number
  commission_rate: number
  commission_amount: number
  status: CommissionStatus
  created_at: string
  updated_at: string
  paid_at: string | null
}

export interface LetterAuditTrail {
  id: string
  letter_id: string
  performed_by: string
  action: string
  old_status: string | null
  new_status: string | null
  notes: string | null
  created_at: string
}

export interface SecurityAuditLog {
  id: string
  user_id: string | null
  action: string
  details: Record<string, any> | null
  ip_address: string | null
  user_agent: string | null
  created_at: string
}

export interface SecurityConfig {
  id: string
  key: string
  value: string | null
  description: string | null
  is_active: boolean
  created_at: string
  updated_at: string
}

export interface CouponUsage {
  id: string
  user_id: string
  employee_id: string | null
  coupon_code: string
  subscription_id: string | null
  discount_percent: number
  amount_before: number
  amount_after: number
  discount_applied: number
  created_at: string
}