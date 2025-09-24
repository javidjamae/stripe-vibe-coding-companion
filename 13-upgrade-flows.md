# Upgrade Flows and Proration Handling

## Overview

This module covers implementing plan upgrade flows, including immediate upgrades with proration, complex upgrade scenarios with interval changes, and the sophisticated upgrade logic found in your codebase.

## Upgrade Flow Architecture

Your codebase implements multiple upgrade scenarios:

1. **Simple Upgrades**: Same interval, higher-priced plan
2. **Complex Upgrades**: Plan upgrade + interval change (e.g., Pro Annual → Scale Monthly)
3. **Interval-Only Changes**: Same plan, different interval (handled as upgrade if higher priced)

## Simple Upgrade Implementation

### Basic Upgrade Logic (Framework-Agnostic)

Our recommended approach uses the core billing system's upgrade function:

```typescript
// Based on packages/core-server patterns
import { upgradeSubscription, BillingDependencies } from './lib/billing'

export async function handleUpgradeRequest(req: Request): Promise<Response> {
  try {
    // Extract user context (implementation varies by framework)
    const user = await getUserFromRequest(req)
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const { newPlanId, newPriceId, billingInterval } = await req.json()
    
    if (!newPlanId) {
      return new Response(
        JSON.stringify({ error: 'Missing newPlanId' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }
    
    // Validate billing interval
    const intervalHint = billingInterval || 'month'
    if (intervalHint !== 'month' && intervalHint !== 'year') {
      return new Response(
        JSON.stringify({ error: 'Invalid billing interval' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Use framework-agnostic billing functions
    const dependencies: BillingDependencies = {
      supabase: createSupabaseClient(),
      stripeSecretKey: process.env.STRIPE_SECRET_KEY!,
      getPlanConfig: (planId) => getPlanConfig(planId),
      getAllPlans: () => getAllPlans()
    }

    const result = await upgradeSubscription({
      userId: user.id,
      newPlanId,
      newPriceId: newPriceId || getStripePriceId(newPlanId, intervalHint),
      billingInterval: intervalHint
    }, dependencies)

    if (!result.success) {
      return new Response(
        JSON.stringify({ error: result.error }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    return new Response(
      JSON.stringify({ 
        success: true,
        message: `Successfully upgraded to ${newPlanId}`
      }),
      { headers: { 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Upgrade failed:', error)
    return new Response(
      JSON.stringify({ error: 'Upgrade failed' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

### Simple Upgrade Handler

```typescript
// lib/upgrade-handlers.ts
export async function handleSimpleUpgrade(
  stripe: Stripe,
  supabase: any,
  subscription: any,
  newPriceId: string,
  newPlanId: string
) {
  console.log('🚀 Processing simple upgrade')
  
  try {
    // Get current subscription from Stripe
    const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
    const subscriptionItemId = stripeSubscription.items.data[0].id

    // Update subscription with new price (immediate with proration)
    const updatedSubscription = await stripe.subscriptions.update(subscription.stripe_subscription_id, {
      items: [{
        id: subscriptionItemId,
        price: newPriceId,
      }],
      proration_behavior: 'create_prorations', // This creates proration
    })

    // Update database with new plan information
    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        stripe_price_id: newPriceId,
        plan_id: newPlanId,
        status: updatedSubscription.status,
        current_period_start: new Date(updatedSubscription.current_period_start * 1000).toISOString(),
        current_period_end: new Date(updatedSubscription.current_period_end * 1000).toISOString(),
        updated_at: new Date().toISOString()
      })
      .eq('id', subscription.id)
      .select()
      .single()

    if (error) {
      console.error('❌ Database update failed:', error)
      throw error
    }

    console.log('✅ Simple upgrade completed')
    return new Response(
      JSON.stringify({
      success: true,
      message: `Successfully upgraded to ${newPlanId}`,
      subscription: data
    })

  } catch (error) {
    console.error('❌ Simple upgrade failed:', error)
    throw error
  }
}
```

## Complex Upgrade Scenarios

Your codebase handles sophisticated upgrade scenarios where users upgrade plans AND change intervals:

### Complex Upgrade Detection

```typescript
// lib/upgrade-logic.ts
export function isComplexUpgradeScenario(
  currentSubscription: any,
  newPlanId: string,
  newInterval: 'month' | 'year'
): boolean {
  // Get current plan and interval from subscription
  const currentPlanId = currentSubscription.plan_id
  const currentPriceId = currentSubscription.stripe_price_id
  const currentInterval = getBillingIntervalFromPrice(currentPriceId)

  // Complex if changing both plan AND interval
  const planChanging = currentPlanId !== newPlanId
  const intervalChanging = currentInterval !== newInterval

  // Special case: Pro Annual → Scale Monthly (upgrade plan + change interval)
  if (planChanging && intervalChanging) {
    const isUpgrade = canUpgradeTo(currentPlanId, newPlanId)
    return isUpgrade
  }

  return false
}
```

### Complex Upgrade Handler

```typescript
export async function handleComplexUpgrade(
  stripe: Stripe,
  supabase: any,
  subscription: any,
  newPlanId: string,
  targetMonthlyPriceId: string,
  newInterval: 'month' | 'year'
) {
  console.log('🔀 Processing complex upgrade (plan + interval change)')
  
  try {
    // Step 1: Upgrade to the new plan's ANNUAL price immediately (for immediate benefits)
    const newAnnualPriceId = getStripePriceId(newPlanId, 'year')
    if (!newAnnualPriceId) {
      throw new Error(`No annual price found for plan ${newPlanId}`)
    }

    const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
    const subscriptionItemId = stripeSubscription.items.data[0].id

    // Immediate upgrade to annual price of new plan (with proration)
    const upgradedSubscription = await stripe.subscriptions.update(subscription.stripe_subscription_id, {
      items: [{
        id: subscriptionItemId,
        price: newAnnualPriceId,
      }],
      proration_behavior: 'create_prorations',
    })

    console.log('✅ Step 1: Upgraded to new plan (annual price)')

    // Step 2: Create subscription schedule to switch to monthly at renewal
    const schedule = await stripe.subscriptionSchedules.create({
      from_subscription: subscription.stripe_subscription_id,
    })

    // Step 3: Update schedule with monthly phase starting at next period
    await stripe.subscriptionSchedules.update(schedule.id, {
      phases: [
        // Current phase: new plan at annual price until period end
        {
          items: [{ price: newAnnualPriceId, quantity: 1 }],
          start_date: upgradedSubscription.current_period_start,
          end_date: upgradedSubscription.current_period_end,
        },
        // Next phase: new plan at monthly price starting at renewal
        {
          items: [{ price: targetMonthlyPriceId, quantity: 1 }],
          start_date: upgradedSubscription.current_period_end,
        }
      ],
      metadata: {
        ffm_interval_switch: '1',
        ffm_target_interval: 'month',
        ffm_target_plan: newPlanId
      }
    })

    console.log('✅ Step 2: Created subscription schedule for interval switch')

    // Step 3: Update database with new plan and scheduled change metadata
    const scheduledChange = {
      planId: newPlanId,
      interval: 'month' as const,
      priceId: targetMonthlyPriceId,
      effectiveAt: new Date(upgradedSubscription.current_period_end * 1000).toISOString(),
    }

    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        stripe_price_id: newAnnualPriceId, // Currently on annual price
        plan_id: newPlanId, // New plan active immediately
        status: upgradedSubscription.status,
        current_period_start: new Date(upgradedSubscription.current_period_start * 1000).toISOString(),
        current_period_end: new Date(upgradedSubscription.current_period_end * 1000).toISOString(),
        cancel_at_period_end: false, // Important: don't set this for interval switches
        metadata: {
          scheduled_change: scheduledChange,
          upgrade_context: {
            original_plan: subscription.plan_id,
            original_interval: getBillingIntervalFromPrice(subscription.stripe_price_id),
            upgrade_type: 'plan_and_interval'
          }
        },
        updated_at: new Date().toISOString()
      })
      .eq('id', subscription.id)
      .select()
      .single()

    if (error) {
      console.error('❌ Database update failed:', error)
      throw error
    }

    console.log('✅ Step 3: Updated database with scheduled change')

    return new Response(
      JSON.stringify({
      success: true,
      message: `Upgraded to ${newPlanId} (switching to monthly billing at renewal)`,
      subscription: data,
      scheduledChange
    })

  } catch (error) {
    console.error('❌ Complex upgrade failed:', error)
    throw error
  }
}
```

## Proration Preview

Allow users to see upgrade costs before committing:

### Proration Preview API

```typescript
// app/api/billing/proration-preview/route.ts
export async function POST(request: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    const { newPriceId } = await request.json()
    if (!newPriceId || typeof newPriceId !== 'string') {
      return new Response(
      JSON.stringify({ error: 'Missing newPriceId' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    // Get user's current subscription
    const { data: subscription, error: subError } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('user_id', user.id)
      .order('updated_at', { ascending: false })
      .limit(1)
      .single()

    if (subError || !subscription?.stripe_subscription_id) {
      return new Response(
      JSON.stringify({ error: 'No active subscription found' ),
      { status: 404 })
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil',
    })

    // Retrieve current subscription from Stripe
    const current = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
    const currentItem = current.items?.data?.[0]
    
    if (!currentItem) {
      return new Response(
      JSON.stringify({ error: 'No subscription item found' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    // Preview upcoming invoice with proration
    const preview = await stripe.invoices.retrieveUpcoming({
      customer: (current.customer as string),
      subscription: current.id,
      subscription_items: [
        { id: currentItem.id, price: newPriceId },
      ],
      subscription_proration_behavior: 'create_prorations',
    })

    const amountDue = (preview.amount_due ?? 0) / 100
    const currency = (preview.currency || 'usd').toUpperCase()

    // Calculate proration details
    const prorationItems = preview.lines.data.filter(item => 
      item.proration === true
    )

    const prorationDetails = prorationItems.map(item => ({
      description: item.description,
      amount: (item.amount ?? 0) / 100,
      period: {
        start: new Date((item.period?.start ?? 0) * 1000).toISOString(),
        end: new Date((item.period?.end ?? 0) * 1000).toISOString()
      }
    }))

    return new Response(
      JSON.stringify({
      ok: true,
      amountDue,
      currency,
      prorationDetails,
      preview: {
        subtotal: (preview.subtotal ?? 0) / 100,
        tax: (preview.tax ?? 0) / 100,
        total: (preview.total ?? 0) / 100
      }
    })
  } catch (error) {
    console.error('Proration preview error:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to compute proration preview' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Frontend Upgrade Implementation

### Upgrade Confirmation Modal

```typescript
// components/billing/UpgradeConfirmationModal.tsx
import { useState, useEffect } from 'react'

interface UpgradeConfirmationModalProps {
  isOpen: boolean
  onClose: () => void
  currentPlan: string
  targetPlan: string
  targetPriceId: string
  billingInterval: 'month' | 'year'
  onConfirm: () => Promise<void>
}

export function UpgradeConfirmationModal({
  isOpen,
  onClose,
  currentPlan,
  targetPlan,
  targetPriceId,
  billingInterval,
  onConfirm
}: UpgradeConfirmationModalProps) {
  const [prorationPreview, setProrationPreview] = useState<any>(null)
  const [loading, setLoading] = useState(false)
  const [upgrading, setUpgrading] = useState(false)

  // Load proration preview when modal opens
  useEffect(() => {
    if (isOpen && targetPriceId) {
      loadProrationPreview()
    }
  }, [isOpen, targetPriceId])

  const loadProrationPreview = async () => {
    setLoading(true)
    try {
      const response = await fetch('/api/billing/proration-preview', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ newPriceId: targetPriceId })
      })

      if (response.ok) {
        const data = await response.json()
        setProrationPreview(data)
      }
    } catch (error) {
      console.error('Failed to load proration preview:', error)
    } finally {
      setLoading(false)
    }
  }

  const handleConfirm = async () => {
    setUpgrading(true)
    try {
      await onConfirm()
      onClose()
    } catch (error) {
      console.error('Upgrade failed:', error)
    } finally {
      setUpgrading(false)
    }
  }

  if (!isOpen) return null

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg p-6 max-w-md w-full mx-4">
        <h3 className="text-lg font-semibold mb-4">
          Upgrade to {targetPlan}
        </h3>

        <div className="mb-4">
          <p className="text-gray-600 mb-2">
            You're upgrading from <strong>{currentPlan}</strong> to <strong>{targetPlan}</strong>.
          </p>
          
          {billingInterval === 'month' && (
            <p className="text-sm text-blue-600">
              Upgrades apply immediately, giving you access to higher plan features right away.
            </p>
          )}
        </div>

        {loading ? (
          <div className="mb-4 p-4 bg-gray-50 rounded">
            <p className="text-sm text-gray-600">Loading pricing information...</p>
          </div>
        ) : prorationPreview ? (
          <div className="mb-4 p-4 bg-gray-50 rounded">
            <h4 className="font-medium mb-2">Billing Summary</h4>
            
            {prorationPreview.prorationDetails.map((item: any, index: number) => (
              <div key={index} className="text-sm text-gray-600 mb-1">
                <div>{item.description}</div>
                <div className="font-medium">${Math.abs(item.amount).toFixed(2)}</div>
              </div>
            ))}
            
            <div className="border-t pt-2 mt-2">
              <div className="flex justify-between font-medium">
                <span>Due today:</span>
                <span>${prorationPreview.amountDue.toFixed(2)}</span>
              </div>
            </div>
            
            <p className="text-xs text-gray-500 mt-2">
              The prorated amount reflects your current billing cycle. 
              Your next billing will be at the full plan price.
            </p>
          </div>
        ) : null}

        <div className="flex space-x-3">
          <button
            onClick={onClose}
            disabled={upgrading}
            className="flex-1 px-4 py-2 border border-gray-300 rounded-md text-gray-700 hover:bg-gray-50 disabled:opacity-50"
          >
            Cancel
          </button>
          <button
            onClick={handleConfirm}
            disabled={upgrading || loading}
            className="flex-1 px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:opacity-50"
          >
            {upgrading ? 'Upgrading...' : 'Confirm Upgrade'}
          </button>
        </div>
      </div>
    </div>
  )
}
```

### Upgrade Hook

```typescript
// hooks/useUpgrade.ts
import { useState } from 'react'

export function useUpgrade() {
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const upgrade = async (planId: string, billingInterval: 'month' | 'year' = 'month') => {
    setLoading(true)
    setError(null)

    try {
      const response = await fetch('/api/billing/upgrade', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ 
          newPlanId: planId,
          billingInterval 
        }),
      })

      const data = await response.json()

      if (!response.ok) {
        throw new Error(data.error || 'Upgrade failed')
      }

      return data
    } catch (err) {
      const message = err instanceof Error ? err.message : 'An error occurred'
      setError(message)
      throw err
    } finally {
      setLoading(false)
    }
  }

  return {
    upgrade,
    loading,
    error
  }
}
```

## Testing Upgrade Flows

### Unit Tests

```typescript
// __tests__/lib/upgrade-handlers.test.ts
import { handleSimpleUpgrade, isComplexUpgradeScenario } from '@/lib/upgrade-handlers'

describe('Upgrade Handlers', () => {
  it('should detect simple upgrade scenarios', () => {
    const subscription = {
      plan_id: 'starter',
      stripe_price_id: 'price_starter_monthly'
    }
    
    const isComplex = isComplexUpgradeScenario(subscription, 'pro', 'month')
    expect(isComplex).toBe(false)
  })

  it('should detect complex upgrade scenarios', () => {
    const subscription = {
      plan_id: 'pro',
      stripe_price_id: 'price_pro_annual'
    }
    
    const isComplex = isComplexUpgradeScenario(subscription, 'scale', 'month')
    expect(isComplex).toBe(true)
  })

  it('should handle simple upgrade', async () => {
    const mockStripe = {
      subscriptions: {
        retrieve: jest.fn().mockResolvedValue({
          items: { data: [{ id: 'si_123' }] }
        }),
        update: jest.fn().mockResolvedValue({
          status: 'active',
          current_period_start: 1640995200,
          current_period_end: 1643673600
        })
      }
    }

    const mockSupabase = {
      from: jest.fn(() => ({
        update: jest.fn(() => ({
          eq: jest.fn(() => ({
            select: jest.fn(() => ({
              single: jest.fn(() => ({ data: { id: 'sub_123' }, error: null }))
            }))
          }))
        }))
      }))
    }

    const subscription = { id: 'sub_123', stripe_subscription_id: 'sub_stripe_123' }
    
    const result = await handleSimpleUpgrade(
      mockStripe as any,
      mockSupabase,
      subscription,
      'price_pro_monthly',
      'pro'
    )

    expect(mockStripe.subscriptions.update).toHaveBeenCalledWith(
      'sub_stripe_123',
      {
        items: [{ id: 'si_123', price: 'price_pro_monthly' }],
        proration_behavior: 'create_prorations'
      }
    )
  })
})
```

### E2E Tests

```typescript
// cypress/e2e/upgrade-flow.cy.ts
describe('Upgrade Flow', () => {
  beforeEach(() => {
    // Login as starter user
    cy.login('starter-user@example.com')
  })

  it('should upgrade from Starter to Pro with proration preview', () => {
    cy.visit('/billing')
    
    // Click upgrade button on Pro plan
    cy.get('[data-testid="pro-action-button"]').click()
    
    // Upgrade modal should appear
    cy.get('[data-testid="upgrade-confirmation-modal"]').should('be.visible')
    
    // Should show proration information
    cy.get('[data-testid="proration-preview"]').should('be.visible')
    cy.get('[data-testid="amount-due"]').should('contain', '$')
    
    // Confirm upgrade
    cy.intercept('POST', '/api/billing/upgrade').as('upgradeRequest')
    cy.get('[data-testid="confirm-upgrade-button"]').click()
    
    // Wait for upgrade to complete
    cy.wait('@upgradeRequest').then((interception) => {
      expect(interception.response?.statusCode).to.eq(200)
    })
    
    // Should show success message
    cy.get('[data-testid="upgrade-success-toast"]').should('be.visible')
    
    // Reload and verify plan change
    cy.reload()
    cy.get('[data-testid="current-plan-name"]').should('contain', 'Pro')
  })
})
```

## Next Steps

In the next module, we'll cover downgrade flows and how to handle scheduled plan changes at the end of billing periods.

## Key Takeaways

- Implement both simple and complex upgrade scenarios
- Use Stripe's proration system for immediate billing adjustments
- Handle plan + interval changes with subscription schedules
- Provide proration previews before upgrades
- Store upgrade context in subscription metadata
- Update database immediately after successful Stripe operations
- Test upgrade flows with real Stripe test data
- Handle upgrade failures gracefully with proper error messages
- Use subscription schedules for complex interval changes
- Validate plan transitions before processing upgrades
