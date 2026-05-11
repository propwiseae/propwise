export type UserPlan = 'basic' | 'pro' | 'agency'

export type Profile = {
  id: string
  email: string
  full_name: string | null
  plan: UserPlan
  stripe_customer_id: string | null
  stripe_subscription_id: string | null
  subscription_status: string | null
  created_at: string
} 