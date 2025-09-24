# Proration Calculations and Preview

## Overview

This module covers understanding and implementing proration calculations for subscription changes. We'll explore how Stripe handles proration, how to preview costs before changes, and how to display proration information clearly to users.

## Understanding Stripe Proration

Stripe automatically calculates proration when subscription changes occur mid-billing cycle:

### Proration Scenarios

1. **Upgrade Mid-Cycle**: Credit unused time, charge for new plan
2. **Plan Changes**: Adjust for price difference over remaining period
3. **Quantity Changes**: Prorate based on usage changes
4. **Interval Changes**: Complex calculation involving period adjustments

### Proration Formula

```
Proration Amount = (New Price - Old Price) × (Days Remaining / Days in Period)
```

## Proration Preview Implementation

### Core Preview Function

```typescript
// lib/proration-preview.ts
import Stripe from 'stripe'

export interface ProrationPreview {
  amountDue: number
  currency: string
  subtotal: number
  tax: number
  total: number
  prorationItems: ProrationItem[]
  nextInvoicePreview?: {
    amount: number
    date: string
  }
}

export interface ProrationItem {
  description: string
  amount: number
  quantity: number
  period: {
    start: string
    end: string
  }
  proration: boolean
  type: 'credit' | 'charge'
}

export async function calculateProrationPreview(
  subscriptionId: string,
  newPriceId: string
): Promise<ProrationPreview> {
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  try {
    // Get current subscription
    const subscription = await stripe.subscriptions.retrieve(subscriptionId, {
      expand: ['items.data.price']
    })

    const currentItem = subscription.items.data[0]
    if (!currentItem) {
      throw new Error('No subscription items found')
    }

    // Preview upcoming invoice with the change
    const preview = await stripe.invoices.retrieveUpcoming({
      customer: subscription.customer as string,
      subscription: subscriptionId,
      subscription_items: [
        {
          id: currentItem.id,
          price: newPriceId,
          quantity: currentItem.quantity
        }
      ],
      subscription_proration_behavior: 'create_prorations',
    })

    // Parse proration items
    const prorationItems: ProrationItem[] = preview.lines.data.map(line => ({
      description: line.description || 'Subscription change',
      amount: (line.amount || 0) / 100,
      quantity: line.quantity || 1,
      period: {
        start: new Date((line.period?.start || 0) * 1000).toISOString(),
        end: new Date((line.period?.end || 0) * 1000).toISOString()
      },
      proration: line.proration || false,
      type: (line.amount || 0) >= 0 ? 'charge' : 'credit'
    }))

    // Calculate next invoice preview
    const nextInvoicePreview = await getNextInvoicePreview(subscriptionId, newPriceId)

    return {
      amountDue: (preview.amount_due || 0) / 100,
      currency: (preview.currency || 'usd').toUpperCase(),
      subtotal: (preview.subtotal || 0) / 100,
      tax: (preview.tax || 0) / 100,
      total: (preview.total || 0) / 100,
      prorationItems,
      nextInvoicePreview
    }

  } catch (error) {
    console.error('Proration calculation failed:', error)
    throw new Error('Unable to calculate proration preview')
  }
}

async function getNextInvoicePreview(subscriptionId: string, newPriceId: string) {
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  try {
    const subscription = await stripe.subscriptions.retrieve(subscriptionId)
    const currentItem = subscription.items.data[0]

    // Preview next regular invoice (after the change)
    const nextPreview = await stripe.invoices.retrieveUpcoming({
      customer: subscription.customer as string,
      subscription: subscriptionId,
      subscription_items: [
        {
          id: currentItem.id,
          price: newPriceId
        }
      ],
      subscription_proration_date: subscription.current_period_end
    })

    return {
      amount: (nextPreview.total || 0) / 100,
      date: new Date(subscription.current_period_end * 1000).toISOString()
    }

  } catch (error) {
    console.error('Next invoice preview failed:', error)
    return null
  }
}
```

### Enhanced API Endpoint

```typescript
// billing/proration-preview.ts - Framework-agnostic proration calculation
import { calculateProrationPreview } from './lib/proration-preview'
import { getStripePriceId } from './lib/plan-config'

export async function handleProrationPreview(request: Request): Promise<Response> {
  try {
    // Extract user context (implementation varies by framework)
    const user = await getUserFromRequest(request)
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const { 
      newPlanId, 
      newPriceId, 
      billingInterval = 'month',
      includeNextInvoice = true 
    } = await request.json()

    if (!newPlanId && !newPriceId) {
      return new Response(
        JSON.stringify({ 
          error: 'Either newPlanId or newPriceId is required' 
        }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
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
        JSON.stringify({ 
          error: 'No active subscription found' 
        }),
        { status: 404, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Determine target price ID
    const targetPriceId = newPriceId || getStripePriceId(newPlanId, billingInterval)
    if (!targetPriceId) {
      return new Response(
        JSON.stringify({ 
          error: 'Invalid plan or billing interval' 
        }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Calculate proration preview
    const preview = await calculateProrationPreview(
      subscription.stripe_subscription_id,
      targetPriceId
    )

    // Add context information
    const response = {
      ...preview,
      context: {
        currentPlan: subscription.plan_id,
        targetPlan: newPlanId,
        billingInterval,
        subscriptionId: subscription.stripe_subscription_id
      },
      breakdown: analyzeProrationBreakdown(preview.prorationItems)
    }

    return new Response(
      JSON.stringify(response),
      { headers: { 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Proration preview error:', error)
    return new Response(
      JSON.stringify({ 
        error: 'Failed to calculate proration preview' 
      }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}

function analyzeProrationBreakdown(items: ProrationItem[]) {
  const credits = items.filter(item => item.type === 'credit')
  const charges = items.filter(item => item.type === 'charge')
  
  const totalCredits = credits.reduce((sum, item) => sum + Math.abs(item.amount), 0)
  const totalCharges = charges.reduce((sum, item) => sum + item.amount, 0)

  return {
    credits: {
      items: credits,
      total: totalCredits
    },
    charges: {
      items: charges,
      total: totalCharges
    },
    netChange: totalCharges - totalCredits
  }
}
```

## Proration Display Components

### Proration Preview Modal

```typescript
// components/billing/ProrationPreviewModal.tsx
import { useState, useEffect } from 'react'
import { XMarkIcon, InformationCircleIcon } from '@heroicons/react/24/outline'

interface ProrationPreviewModalProps {
  isOpen: boolean
  onClose: () => void
  currentPlan: string
  targetPlan: string
  targetPriceId: string
  billingInterval: 'month' | 'year'
  onConfirm: () => Promise<void>
}

export function ProrationPreviewModal({
  isOpen,
  onClose,
  currentPlan,
  targetPlan,
  targetPriceId,
  billingInterval,
  onConfirm
}: ProrationPreviewModalProps) {
  const [preview, setPreview] = useState<any>(null)
  const [loading, setLoading] = useState(false)
  const [confirming, setConfirming] = useState(false)

  useEffect(() => {
    if (isOpen) {
      loadPreview()
    }
  }, [isOpen, targetPriceId])

  const loadPreview = async () => {
    setLoading(true)
    try {
      const response = await fetch('/api/billing/proration-preview', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          newPlanId: targetPlan,
          newPriceId: targetPriceId,
          billingInterval,
          includeNextInvoice: true
        })
      })

      if (response.ok) {
        const data = await response.json()
        setPreview(data)
      } else {
        throw new Error('Failed to load preview')
      }
    } catch (error) {
      console.error('Preview loading failed:', error)
      setPreview({ error: 'Unable to load pricing preview' })
    } finally {
      setLoading(false)
    }
  }

  const handleConfirm = async () => {
    setConfirming(true)
    try {
      await onConfirm()
      onClose()
    } catch (error) {
      console.error('Upgrade failed:', error)
    } finally {
      setConfirming(false)
    }
  }

  if (!isOpen) return null

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50">
      <div className="bg-white rounded-lg max-w-2xl w-full mx-4 max-h-[90vh] overflow-y-auto">
        {/* Header */}
        <div className="flex items-center justify-between p-6 border-b">
          <h3 className="text-lg font-semibold text-gray-900">
            Upgrade to {targetPlan}
          </h3>
          <button
            onClick={onClose}
            className="text-gray-400 hover:text-gray-600"
          >
            <XMarkIcon className="h-6 w-6" />
          </button>
        </div>

        {/* Content */}
        <div className="p-6">
          {loading ? (
            <div className="text-center py-8">
              <div className="animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600 mx-auto"></div>
              <p className="mt-2 text-gray-600">Calculating costs...</p>
            </div>
          ) : preview?.error ? (
            <div className="text-center py-8">
              <p className="text-red-600">{preview.error}</p>
            </div>
          ) : preview ? (
            <div className="space-y-6">
              {/* Plan Change Summary */}
              <div className="bg-blue-50 rounded-lg p-4">
                <div className="flex items-start">
                  <InformationCircleIcon className="h-5 w-5 text-blue-400 mt-0.5" />
                  <div className="ml-3">
                    <h4 className="text-sm font-medium text-blue-800">
                      Plan Change Summary
                    </h4>
                    <p className="text-sm text-blue-700 mt-1">
                      Upgrading from <strong>{currentPlan}</strong> to <strong>{targetPlan}</strong>
                      {billingInterval === 'year' ? ' (Annual)' : ' (Monthly)'}
                    </p>
                    <p className="text-sm text-blue-700 mt-1">
                      The upgrade will take effect immediately, and you'll get access to 
                      all {targetPlan} features right away.
                    </p>
                  </div>
                </div>
              </div>

              {/* Proration Breakdown */}
              <div>
                <h4 className="text-sm font-medium text-gray-900 mb-3">
                  Billing Adjustment
                </h4>
                <div className="bg-gray-50 rounded-lg p-4">
                  {preview.prorationItems.map((item: any, index: number) => (
                    <div key={index} className="flex justify-between items-start py-2">
                      <div className="flex-1">
                        <p className="text-sm text-gray-900">{item.description}</p>
                        <p className="text-xs text-gray-500">
                          {new Date(item.period.start).toLocaleDateString()} - {new Date(item.period.end).toLocaleDateString()}
                        </p>
                      </div>
                      <div className="text-right">
                        <span className={`text-sm font-medium ${
                          item.type === 'credit' ? 'text-green-600' : 'text-gray-900'
                        }`}>
                          {item.type === 'credit' ? '-' : ''}${Math.abs(item.amount).toFixed(2)}
                        </span>
                      </div>
                    </div>
                  ))}
                  
                  <div className="border-t pt-3 mt-3">
                    <div className="flex justify-between items-center">
                      <span className="text-base font-medium text-gray-900">
                        Due Today
                      </span>
                      <span className="text-lg font-bold text-gray-900">
                        ${preview.amountDue.toFixed(2)}
                      </span>
                    </div>
                  </div>
                </div>
              </div>

              {/* Next Invoice Preview */}
              {preview.nextInvoicePreview && (
                <div>
                  <h4 className="text-sm font-medium text-gray-900 mb-3">
                    Next Billing Cycle
                  </h4>
                  <div className="bg-gray-50 rounded-lg p-4">
                    <div className="flex justify-between items-center">
                      <div>
                        <p className="text-sm text-gray-900">
                          Next invoice ({new Date(preview.nextInvoicePreview.date).toLocaleDateString()})
                        </p>
                        <p className="text-xs text-gray-500">
                          Full {targetPlan} plan billing
                        </p>
                      </div>
                      <span className="text-sm font-medium text-gray-900">
                        ${preview.nextInvoicePreview.amount.toFixed(2)}
                      </span>
                    </div>
                  </div>
                </div>
              )}

              {/* Breakdown Analysis */}
              {preview.breakdown && (
                <div className="text-xs text-gray-500 bg-gray-50 rounded p-3">
                  <p><strong>Breakdown:</strong></p>
                  <p>• Credits for unused time: -${preview.breakdown.credits.total.toFixed(2)}</p>
                  <p>• Charges for new plan: +${preview.breakdown.charges.total.toFixed(2)}</p>
                  <p>• Net change: ${preview.breakdown.netChange.toFixed(2)}</p>
                </div>
              )}
            </div>
          ) : null}
        </div>

        {/* Footer */}
        {preview && !preview.error && (
          <div className="flex justify-end space-x-3 p-6 border-t">
            <button
              onClick={onClose}
              disabled={confirming}
              className="px-4 py-2 border border-gray-300 rounded-md text-gray-700 hover:bg-gray-50 disabled:opacity-50"
            >
              Cancel
            </button>
            <button
              onClick={handleConfirm}
              disabled={confirming}
              className="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:opacity-50"
            >
              {confirming ? 'Processing...' : `Confirm Upgrade - $${preview.amountDue.toFixed(2)}`}
            </button>
          </div>
        )}
      </div>
    </div>
  )
}
```

### Inline Proration Display

```typescript
// components/billing/ProrationInline.tsx
import { useState, useEffect } from 'react'
import { InformationCircleIcon } from '@heroicons/react/24/outline'

interface ProrationInlineProps {
  currentPlan: string
  targetPlan: string
  targetPriceId: string
  billingInterval: 'month' | 'year'
  compact?: boolean
}

export function ProrationInline({
  currentPlan,
  targetPlan,
  targetPriceId,
  billingInterval,
  compact = false
}: ProrationInlineProps) {
  const [preview, setPreview] = useState<any>(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    loadPreview()
  }, [targetPriceId])

  const loadPreview = async () => {
    setLoading(true)
    try {
      const response = await fetch('/api/billing/proration-preview', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          newPlanId: targetPlan,
          newPriceId: targetPriceId,
          billingInterval
        })
      })

      if (response.ok) {
        const data = await response.json()
        setPreview(data)
      }
    } catch (error) {
      console.error('Preview loading failed:', error)
    } finally {
      setLoading(false)
    }
  }

  if (loading) {
    return (
      <div className="animate-pulse bg-gray-200 rounded h-4 w-24"></div>
    )
  }

  if (!preview || preview.error) {
    return null
  }

  if (compact) {
    return (
      <div className="text-sm text-gray-600">
        Due today: <span className="font-medium">${preview.amountDue.toFixed(2)}</span>
      </div>
    )
  }

  return (
    <div className="bg-blue-50 border border-blue-200 rounded-md p-3">
      <div className="flex items-start">
        <InformationCircleIcon className="h-4 w-4 text-blue-400 mt-0.5" />
        <div className="ml-2 text-sm">
          <p className="text-blue-800 font-medium">
            Upgrade Cost: ${preview.amountDue.toFixed(2)}
          </p>
          <p className="text-blue-700 text-xs mt-1">
            Prorated for the remaining {Math.ceil(
              (new Date(preview.prorationItems[0]?.period.end || Date.now()).getTime() - Date.now()) 
              / (1000 * 60 * 60 * 24)
            )} days in your billing cycle
          </p>
        </div>
      </div>
    </div>
  )
}
```

## Advanced Proration Scenarios

### Multi-Item Subscriptions

```typescript
// lib/advanced-proration.ts
export async function calculateMultiItemProration(
  subscriptionId: string,
  itemChanges: Array<{
    itemId: string
    newPriceId: string
    quantity?: number
  }>
): Promise<ProrationPreview> {
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  const subscription = await stripe.subscriptions.retrieve(subscriptionId)

  // Build subscription items array with changes
  const subscriptionItems = itemChanges.map(change => ({
    id: change.itemId,
    price: change.newPriceId,
    quantity: change.quantity || 1
  }))

  const preview = await stripe.invoices.retrieveUpcoming({
    customer: subscription.customer as string,
    subscription: subscriptionId,
    subscription_items: subscriptionItems,
    subscription_proration_behavior: 'create_prorations'
  })

  // Process and return preview data
  return processInvoicePreview(preview)
}
```

### Quantity-Based Proration

```typescript
export async function calculateQuantityProration(
  subscriptionId: string,
  itemId: string,
  newQuantity: number
): Promise<ProrationPreview> {
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  const subscription = await stripe.subscriptions.retrieve(subscriptionId)
  const currentItem = subscription.items.data.find(item => item.id === itemId)

  if (!currentItem) {
    throw new Error('Subscription item not found')
  }

  const preview = await stripe.invoices.retrieveUpcoming({
    customer: subscription.customer as string,
    subscription: subscriptionId,
    subscription_items: [{
      id: itemId,
      quantity: newQuantity
    }],
    subscription_proration_behavior: 'create_prorations'
  })

  return processInvoicePreview(preview)
}
```

## Proration Hooks

### Proration Preview Hook

```typescript
// hooks/useProrationPreview.ts
import { useState, useCallback } from 'react'

export function useProrationPreview() {
  const [preview, setPreview] = useState<any>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const calculatePreview = useCallback(async (params: {
    newPlanId?: string
    newPriceId?: string
    billingInterval?: 'month' | 'year'
    quantity?: number
  }) => {
    setLoading(true)
    setError(null)

    try {
      const response = await fetch('/api/billing/proration-preview', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(params)
      })

      if (!response.ok) {
        const errorData = await response.json()
        throw new Error(errorData.error || 'Preview calculation failed')
      }

      const data = await response.json()
      setPreview(data)
      return data
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Unknown error'
      setError(errorMessage)
      throw err
    } finally {
      setLoading(false)
    }
  }, [])

  const clearPreview = useCallback(() => {
    setPreview(null)
    setError(null)
  }, [])

  return {
    preview,
    loading,
    error,
    calculatePreview,
    clearPreview
  }
}
```

## Testing Proration Calculations

### Unit Tests

```typescript
// __tests__/lib/proration-preview.test.ts
import { calculateProrationPreview } from '@/lib/proration-preview'

// Mock Stripe
jest.mock('stripe')

describe('Proration Preview', () => {
  const mockStripe = {
    subscriptions: {
      retrieve: jest.fn()
    },
    invoices: {
      retrieveUpcoming: jest.fn()
    }
  }

  beforeEach(() => {
    jest.clearAllMocks()
  })

  it('should calculate upgrade proration correctly', async () => {
    mockStripe.subscriptions.retrieve.mockResolvedValue({
      id: 'sub_123',
      customer: 'cus_123',
      items: {
        data: [{
          id: 'si_123',
          price: { id: 'price_starter' },
          quantity: 1
        }]
      }
    })

    mockStripe.invoices.retrieveUpcoming.mockResolvedValue({
      amount_due: 5000, // $50.00
      subtotal: 5000,
      tax: 0,
      total: 5000,
      currency: 'usd',
      lines: {
        data: [
          {
            description: 'Unused time on Starter plan',
            amount: -1000, // -$10.00 credit
            proration: true,
            period: { start: 1640995200, end: 1643673600 }
          },
          {
            description: 'Pro plan (prorated)',
            amount: 6000, // $60.00 charge
            proration: true,
            period: { start: 1640995200, end: 1643673600 }
          }
        ]
      }
    })

    const preview = await calculateProrationPreview('sub_123', 'price_pro')

    expect(preview.amountDue).toBe(50.00)
    expect(preview.prorationItems).toHaveLength(2)
    expect(preview.prorationItems[0].type).toBe('credit')
    expect(preview.prorationItems[1].type).toBe('charge')
  })

  it('should handle proration calculation errors', async () => {
    mockStripe.subscriptions.retrieve.mockRejectedValue(
      new Error('Subscription not found')
    )

    await expect(
      calculateProrationPreview('invalid_sub', 'price_pro')
    ).rejects.toThrow('Unable to calculate proration preview')
  })
})
```

### Integration Tests

```typescript
// cypress/e2e/proration-preview.cy.ts
describe('Proration Preview', () => {
  beforeEach(() => {
    cy.seedStarterUser({ email: 'starter@example.com' })
    cy.login('starter@example.com')
  })

  it('should show proration preview in upgrade modal', () => {
    cy.visit('/billing')

    // Click upgrade to Pro
    cy.get('[data-testid="pro-action-button"]').click()

    // Should show upgrade modal with proration
    cy.get('[data-testid="upgrade-confirmation-modal"]').should('be.visible')
    cy.get('[data-testid="proration-preview"]').should('be.visible')

    // Should show due today amount
    cy.get('[data-testid="amount-due"]').should('contain', '$')

    // Should show proration breakdown
    cy.get('[data-testid="proration-items"]').should('be.visible')
    cy.get('[data-testid="proration-item"]').should('have.length.at.least', 1)

    // Should show next invoice preview
    cy.get('[data-testid="next-invoice-preview"]').should('be.visible')
  })

  it('should handle proration preview loading states', () => {
    // Intercept with delay to test loading state
    cy.intercept('POST', '/api/billing/proration-preview', {
      delay: 2000,
      body: { amountDue: 50.00, prorationItems: [] }
    }).as('prorationPreview')

    cy.visit('/billing')
    cy.get('[data-testid="pro-action-button"]').click()

    // Should show loading state
    cy.get('[data-testid="proration-loading"]').should('be.visible')

    cy.wait('@prorationPreview')

    // Should show loaded preview
    cy.get('[data-testid="proration-preview"]').should('be.visible')
  })
})
```

## Next Steps

In the next module, we'll cover interval changes (monthly ↔ annual) and the complex scenarios that arise when changing billing frequencies.

## Key Takeaways

- Understand how Stripe calculates proration automatically
- Implement preview functionality to show costs before changes
- Display proration breakdowns clearly with credits and charges
- Handle complex scenarios like multi-item and quantity changes
- Use hooks for clean proration preview integration
- Show loading states during preview calculations
- Test proration calculations with realistic scenarios
- Provide context about billing periods and next invoices
- Handle proration errors gracefully with fallback messages
- Use inline previews for quick cost estimates
