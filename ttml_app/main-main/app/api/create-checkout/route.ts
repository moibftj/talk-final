import { createClient } from '@/lib/supabase/server'
import { NextRequest, NextResponse } from 'next/server'
import Stripe from 'stripe'

const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
  apiVersion: '2025-01-27.acacia',
})

export async function POST(request: NextRequest) {
  try {
    const supabase = await createClient()

    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError || !user) {
      return NextResponse.json({ error: 'Unauthorized' }, { status: 401 })
    }

    const body = await request.json()
    const { planType, couponCode } = body

    let discount = 0
    let employeeId = null
    let isSuperUserCoupon = false
    let couponId = null

    // TASK 1 FIX: Handle TALK3 special coupon BEFORE database lookup
    if (couponCode?.toUpperCase() === 'TALK3') {
      discount = 100 // 100% discount
      // IMPORTANT: For TALK3, employee still gets 5% commission
      // We need to find an employee to attribute this to, or handle specially
      // For now, we'll set employeeId to null but track it differently
      isSuperUserCoupon = false // TALK3 is NOT a super user coupon
    } else if (couponCode) {
      // Check employee coupons in database (including special promo codes)
      const { data: coupon } = await supabase
        .from('employee_coupons')
        .select('*')
        .eq('code', couponCode)
        .eq('is_active', true)
        .single()

      if (coupon) {
        discount = coupon.discount_percent
        employeeId = coupon.employee_id
        couponId = coupon.id

        // If 100% discount, mark as super user
        if (discount === 100) {
          isSuperUserCoupon = true
        }
      }
    }

    const planConfig: Record<string, { price: number, letters: number, planType: string, name: string }> = {
      'one_time': { price: 299, letters: 1, planType: 'one_time', name: 'Single Letter' },
      'standard_4_month': { price: 299, letters: 4, planType: 'standard_4_month', name: 'Monthly Plan' },
      'premium_8_month': { price: 599, letters: 8, planType: 'premium_8_month', name: 'Yearly Plan' }
    }

    const selectedPlan = planConfig[planType]
    if (!selectedPlan) {
      return NextResponse.json({ error: 'Invalid plan type' }, { status: 400 })
    }

    const basePrice = selectedPlan.price
    const discountAmount = (basePrice * discount) / 100
    const finalPrice = basePrice - discountAmount

    // If 100% discount, create subscription directly without payment
    if (finalPrice === 0) {
      const { data: subscription, error: subError } = await supabase
        .from('subscriptions')
        .insert({
          user_id: user.id,
          plan: planType,
          plan_type: selectedPlan.planType,
          status: 'active',
          price: finalPrice,
          discount: discountAmount,
          coupon_code: couponCode || null,
          remaining_letters: selectedPlan.letters,
          credits_remaining: selectedPlan.letters,
          last_reset_at: new Date().toISOString(),
          current_period_start: new Date().toISOString(),
          current_period_end: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString()
        })
        .select()
        .single()

      if (subError) {
        console.error('[Checkout] Subscription creation error:', subError)
        throw new Error(`Failed to create subscription: ${subError.message}`)
      }

      if (isSuperUserCoupon) {
        const { error: profileError } = await supabase
          .from('profiles')
          .update({ is_super_user: true })
          .eq('id', user.id)

        if (profileError) {
          console.error('[Checkout] Profile update error:', profileError)
        }
      }

      if (couponCode) {
        const { error: usageError } = await supabase
          .from('coupon_usage')
          .insert({
            user_id: user.id,
            coupon_code: couponCode,
            employee_id: employeeId,
            discount_percent: discount,
            amount_before: basePrice,
            amount_after: finalPrice
          })

        if (usageError) {
          console.error('[Checkout] Coupon usage tracking error:', usageError)
          // Don't fail the checkout if usage tracking fails
        }
      }

      // TASK 1 FIX: For TALK3, create commission even though it's 100% discount
      // Employee gets 5% commission on the original price
      if (employeeId && subscription) {
        const commissionAmount = basePrice * 0.05 // 5% of original price

        const { error: commissionError } = await supabase
          .from('commissions')
          .insert({
            employee_id: employeeId,
            subscription_id: subscription.id,
            subscription_amount: basePrice, // Use original price for commission calculation
            commission_rate: 0.05,
            commission_amount: commissionAmount,
            status: 'pending'
          })

        if (commissionError) {
          console.error('[Checkout] Commission creation error:', commissionError)
        }

        // Update coupon usage count
        const { data: currentCoupon } = await supabase
          .from('employee_coupons')
          .select('usage_count')
          .eq('code', couponCode)
          .maybeSingle()

        const { error: updateError } = await supabase
          .from('employee_coupons')
          .update({
            usage_count: (currentCoupon?.usage_count || 0) + 1,
            updated_at: new Date().toISOString()
          })
          .eq('code', couponCode)

        if (updateError) {
          console.error('[Checkout] Coupon update error:', updateError)
        }
      }

      return NextResponse.json({
        success: true,
        subscriptionId: subscription.id,
        letters: selectedPlan.letters,
        message: 'Subscription created successfully'
      })
    }

    // Create Stripe Checkout Session for paid plans
    const origin = request.headers.get('origin') || process.env.NEXT_PUBLIC_APP_URL || 'http://localhost:3000'

    const session = await stripe.checkout.sessions.create({
      mode: 'payment',
      payment_method_types: ['card'],
      line_items: [
        {
          price_data: {
            currency: 'usd',
            product_data: {
              name: selectedPlan.name,
              description: `${selectedPlan.letters} Legal ${selectedPlan.letters === 1 ? 'Letter' : 'Letters'}`,
            },
            unit_amount: Math.round(finalPrice * 100), // Convert to cents
          },
          quantity: 1,
        },
      ],
      success_url: `${origin}/dashboard/subscription?success=true&session_id={CHECKOUT_SESSION_ID}`,
      cancel_url: `${origin}/dashboard/subscription?canceled=true`,
      client_reference_id: user.id,
      metadata: {
        user_id: user.id,
        plan_type: planType,
        letters: selectedPlan.letters.toString(),
        base_price: basePrice.toString(),
        discount: discountAmount.toString(),
        final_price: finalPrice.toString(),
        coupon_code: couponCode || '',
        employee_id: employeeId || '',
        is_super_user_coupon: isSuperUserCoupon.toString(),
        coupon_id: couponId || ''
      }
    })

    return NextResponse.json({
      sessionId: session.id,
      url: session.url
    })

  } catch (error: any) {
    console.error('[Checkout] Error:', error)
    return NextResponse.json(
      {
        error: 'Failed to create checkout',
        details: error.message || 'Unknown error'
      },
      { status: 500 }
    )
  }
}