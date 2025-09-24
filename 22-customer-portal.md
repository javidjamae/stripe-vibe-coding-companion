# Stripe Customer Portal vs Custom Interfaces

## Overview

This module covers the tradeoffs between using Stripe's hosted Customer Portal versus building custom billing interfaces. We'll explore when to use each approach and how to implement both effectively based on your codebase patterns.

## Customer Portal Overview

Stripe's Customer Portal provides a hosted billing interface where customers can:

- Update payment methods
- View billing history and invoices
- Download receipts
- Update billing information
- Cancel or modify subscriptions
- Manage tax information

## When to Use Customer Portal

### Advantages of Customer Portal

1. **Rapid Implementation**: No custom UI development required
2. **Stripe Compliance**: Automatically handles PCI compliance
3. **Feature Complete**: All billing operations supported out of the box
4. **Mobile Optimized**: Responsive design works on all devices
5. **Localization**: Supports multiple languages automatically
6. **Security**: Hosted by Stripe with enterprise-grade security

### Best Use Cases

- **MVP/Early Stage**: Get billing features quickly
- **Compliance Requirements**: PCI compliance without certification
- **Limited Development Resources**: No need to build custom UI
- **Standard Billing Needs**: Common subscription operations

## Customer Portal Implementation

### Basic Portal Integration

```typescript
// billing/create-portal-session.ts - Framework-agnostic portal session creation
import { createCustomerPortalSession, BillingDependencies } from './lib/billing'

export async function handleCreatePortalSession(request: Request): Promise<Response> {
  try {
    // Extract user context (implementation varies by framework)
    const user = await getUserFromRequest(request)
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Get user's Stripe customer ID
    const { data: subscription } = await supabase
      .from('subscriptions')
      .select('stripe_customer_id')
      .eq('user_id', user.id)
      .single()

    if (!subscription?.stripe_customer_id) {
      return new Response(
        JSON.stringify({ error: 'No customer found' }),
        { status: 404, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Use framework-agnostic billing functions
    const dependencies: BillingDependencies = {
      supabase: createSupabaseClient(),
      stripeSecretKey: process.env.STRIPE_SECRET_KEY!,
      getPlanConfig: (planId) => getPlanConfig(planId),
      getAllPlans: () => getAllPlans()
    }

    const session = await createCustomerPortalSession({
      userId: user.id,
      returnUrl: `${process.env.APP_URL}/billing`
    }, dependencies)

    return new Response(
      JSON.stringify(session),
      { headers: { 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    console.error('Portal session creation failed:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to create portal session' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

### Portal Configuration

```typescript
// lib/portal-configuration.ts
export async function createCustomPortalConfiguration(): Promise<string> {
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  const configuration = await stripe.billingPortal.configurations.create({
    business_profile: {
      headline: 'Manage your FFmpeg Micro subscription',
      privacy_policy_url: `${process.env.APP_URL}/privacy`,
      terms_of_service_url: `${process.env.APP_URL}/terms`,
    },
    features: {
      // Payment method management
      payment_method_update: {
        enabled: true,
      },
      
      // Invoice history
      invoice_history: {
        enabled: true,
      },
      
      // Customer information updates
      customer_update: {
        enabled: true,
        allowed_updates: ['email', 'name', 'phone', 'address', 'tax_id'],
      },
      
      // Subscription cancellation
      subscription_cancel: {
        enabled: true,
        mode: 'at_period_end', // Align with your cancellation strategy
        cancellation_reason: {
          enabled: true,
          options: [
            'too_expensive',
            'missing_features', 
            'switched_service',
            'unused',
            'customer_service',
            'other'
          ]
        }
      },
      
      // Subscription updates (plan changes)
      subscription_update: {
        enabled: true,
        default_allowed_updates: ['price'],
        proration_behavior: 'create_prorations',
        products: [
          {
            product: process.env.STRIPE_STARTER_PRODUCT_ID!,
            prices: [
              process.env.STRIPE_STARTER_MONTHLY_PRICE_ID!,
              process.env.STRIPE_STARTER_ANNUAL_PRICE_ID!
            ]
          },
          {
            product: process.env.STRIPE_PRO_PRODUCT_ID!,
            prices: [
              process.env.STRIPE_PRO_MONTHLY_PRICE_ID!,
              process.env.STRIPE_PRO_ANNUAL_PRICE_ID!
            ]
          }
          // Add other products/prices as needed
        ]
      }
    }
  })

  console.log('✅ Portal configuration created:', configuration.id)
  return configuration.id
}
```

### Portal Button Component

```typescript
// components/billing/CustomerPortalButton.tsx
import { useState } from 'react'
import { ExternalLinkIcon } from '@heroicons/react/24/outline'

interface CustomerPortalButtonProps {
  variant?: 'primary' | 'secondary'
  size?: 'sm' | 'md' | 'lg'
  fullWidth?: boolean
}

export function CustomerPortalButton({ 
  variant = 'secondary', 
  size = 'md',
  fullWidth = false 
}: CustomerPortalButtonProps) {
  const [loading, setLoading] = useState(false)

  const openPortal = async () => {
    setLoading(true)
    try {
      const response = await fetch('/api/billing/create-portal-session', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' }
      })

      if (!response.ok) {
        throw new Error('Failed to create portal session')
      }

      const { url } = await response.json()
      window.location.href = url

    } catch (error) {
      console.error('Portal access failed:', error)
      // Show error toast or message
    } finally {
      setLoading(false)
    }
  }

  const getButtonClasses = () => {
    const base = 'inline-flex items-center justify-center font-medium rounded-md transition-colors'
    
    const sizeClasses = {
      sm: 'px-3 py-1.5 text-sm',
      md: 'px-4 py-2 text-sm',
      lg: 'px-6 py-3 text-base'
    }

    const variantClasses = {
      primary: 'bg-blue-600 text-white hover:bg-blue-700',
      secondary: 'bg-gray-100 text-gray-900 hover:bg-gray-200 border border-gray-300'
    }

    const widthClass = fullWidth ? 'w-full' : ''

    return `${base} ${sizeClasses[size]} ${variantClasses[variant]} ${widthClass}`
  }

  return (
    <button
      onClick={openPortal}
      disabled={loading}
      className={`${getButtonClasses()} ${loading ? 'opacity-50 cursor-not-allowed' : ''}`}
    >
      {loading ? (
        <>
          <div className="animate-spin rounded-full h-4 w-4 border-b-2 border-current mr-2"></div>
          Loading...
        </>
      ) : (
        <>
          <span>Manage Billing</span>
          <ExternalLinkIcon className="ml-2 h-4 w-4" />
        </>
      )}
    </button>
  )
}
```

## Custom Interface Implementation

### When to Build Custom Interfaces

1. **Brand Consistency**: Match your app's design system
2. **Custom Workflows**: Unique business logic or flows
3. **Enhanced UX**: Streamlined experience within your app
4. **Advanced Features**: Features not available in portal
5. **Data Integration**: Combine billing with other app data

### Custom Billing Dashboard

```typescript
// components/billing/CustomBillingDashboard.tsx
import { useState, useEffect } from 'react'
import { useSubscription } from '@/hooks/useSubscription'
import { useInvoiceHistory } from '@/hooks/useInvoiceHistory'
import { PaymentMethodManager } from './PaymentMethodManager'
import { InvoiceHistory } from './InvoiceHistory'
import { SubscriptionControls } from './SubscriptionControls'

export function CustomBillingDashboard() {
  const { subscription, loading: subLoading } = useSubscription()
  const { invoices, loading: invoiceLoading } = useInvoiceHistory()
  const [activeTab, setActiveTab] = useState<'overview' | 'payment' | 'history'>('overview')

  if (subLoading) {
    return <div className="animate-pulse bg-gray-200 rounded h-64 w-full"></div>
  }

  if (!subscription) {
    return (
      <div className="text-center py-8">
        <p className="text-gray-600">No active subscription found.</p>
        <button
          onClick={() => window.location.href = '/pricing'}
          className="mt-4 bg-blue-600 text-white px-4 py-2 rounded-md hover:bg-blue-700"
        >
          View Plans
        </button>
      </div>
    )
  }

  return (
    <div className="max-w-4xl mx-auto">
      {/* Tab Navigation */}
      <div className="border-b border-gray-200 mb-6">
        <nav className="-mb-px flex space-x-8">
          {[
            { id: 'overview', label: 'Overview' },
            { id: 'payment', label: 'Payment Methods' },
            { id: 'history', label: 'Billing History' }
          ].map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id as any)}
              className={`py-2 px-1 border-b-2 font-medium text-sm ${
                activeTab === tab.id
                  ? 'border-blue-500 text-blue-600'
                  : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'
              }`}
            >
              {tab.label}
            </button>
          ))}
        </nav>
      </div>

      {/* Tab Content */}
      {activeTab === 'overview' && (
        <div className="space-y-6">
          <SubscriptionOverview subscription={subscription} />
          <SubscriptionControls subscription={subscription} />
        </div>
      )}

      {activeTab === 'payment' && (
        <PaymentMethodManager customerId={subscription.stripe_customer_id} />
      )}

      {activeTab === 'history' && (
        <InvoiceHistory 
          invoices={invoices} 
          loading={invoiceLoading} 
        />
      )}
    </div>
  )
}
```

### Payment Method Management

```typescript
// components/billing/PaymentMethodManager.tsx
import { useState, useEffect } from 'react'
import { CreditCardIcon, PlusIcon } from '@heroicons/react/24/outline'

interface PaymentMethodManagerProps {
  customerId: string
}

export function PaymentMethodManager({ customerId }: PaymentMethodManagerProps) {
  const [paymentMethods, setPaymentMethods] = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [defaultPaymentMethod, setDefaultPaymentMethod] = useState<string | null>(null)

  useEffect(() => {
    loadPaymentMethods()
  }, [customerId])

  const loadPaymentMethods = async () => {
    setLoading(true)
    try {
      const response = await fetch(`/api/billing/payment-methods?customerId=${customerId}`)
      if (response.ok) {
        const data = await response.json()
        setPaymentMethods(data.paymentMethods || [])
        setDefaultPaymentMethod(data.defaultPaymentMethod)
      }
    } catch (error) {
      console.error('Failed to load payment methods:', error)
    } finally {
      setLoading(false)
    }
  }

  const setDefaultMethod = async (paymentMethodId: string) => {
    try {
      const response = await fetch('/api/billing/set-default-payment-method', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ paymentMethodId })
      })

      if (response.ok) {
        setDefaultPaymentMethod(paymentMethodId)
      }
    } catch (error) {
      console.error('Failed to set default payment method:', error)
    }
  }

  const deletePaymentMethod = async (paymentMethodId: string) => {
    try {
      const response = await fetch('/api/billing/delete-payment-method', {
        method: 'DELETE',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ paymentMethodId })
      })

      if (response.ok) {
        await loadPaymentMethods()
      }
    } catch (error) {
      console.error('Failed to delete payment method:', error)
    }
  }

  if (loading) {
    return <div className="animate-pulse bg-gray-200 rounded h-32 w-full"></div>
  }

  return (
    <div>
      <div className="flex justify-between items-center mb-6">
        <h3 className="text-lg font-medium">Payment Methods</h3>
        <button
          onClick={() => {/* Implement add payment method */}}
          className="bg-blue-600 text-white px-4 py-2 rounded-md hover:bg-blue-700 inline-flex items-center"
        >
          <PlusIcon className="h-4 w-4 mr-2" />
          Add Payment Method
        </button>
      </div>

      {paymentMethods.length === 0 ? (
        <div className="text-center py-8 bg-gray-50 rounded-lg">
          <CreditCardIcon className="h-12 w-12 text-gray-400 mx-auto mb-4" />
          <p className="text-gray-600">No payment methods on file</p>
        </div>
      ) : (
        <div className="space-y-4">
          {paymentMethods.map((pm) => (
            <div key={pm.id} className="border rounded-lg p-4 flex items-center justify-between">
              <div className="flex items-center">
                <CreditCardIcon className="h-6 w-6 text-gray-400 mr-3" />
                <div>
                  <p className="font-medium">
                    •••• •••• •••• {pm.card?.last4}
                  </p>
                  <p className="text-sm text-gray-600">
                    {pm.card?.brand?.toUpperCase()} expires {pm.card?.exp_month}/{pm.card?.exp_year}
                  </p>
                  {defaultPaymentMethod === pm.id && (
                    <span className="inline-flex items-center px-2 py-1 rounded-full text-xs font-medium bg-green-100 text-green-800 mt-1">
                      Default
                    </span>
                  )}
                </div>
              </div>
              
              <div className="flex space-x-2">
                {defaultPaymentMethod !== pm.id && (
                  <button
                    onClick={() => setDefaultMethod(pm.id)}
                    className="text-sm text-blue-600 hover:text-blue-700"
                  >
                    Set Default
                  </button>
                )}
                <button
                  onClick={() => deletePaymentMethod(pm.id)}
                  className="text-sm text-red-600 hover:text-red-700"
                  disabled={paymentMethods.length === 1}
                >
                  Delete
                </button>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
```

## Custom vs Portal Comparison

### Feature Comparison Matrix

| Feature | Customer Portal | Custom Interface |
|---------|----------------|------------------|
| **Development Time** | ⭐⭐⭐⭐⭐ Immediate | ⭐⭐ Weeks/Months |
| **Customization** | ⭐⭐ Limited | ⭐⭐⭐⭐⭐ Full Control |
| **Brand Consistency** | ⭐⭐ Stripe Branding | ⭐⭐⭐⭐⭐ Your Brand |
| **Mobile Experience** | ⭐⭐⭐⭐⭐ Optimized | ⭐⭐⭐⭐ Your Implementation |
| **PCI Compliance** | ⭐⭐⭐⭐⭐ Automatic | ⭐⭐⭐ Requires Work |
| **Feature Completeness** | ⭐⭐⭐⭐⭐ All Features | ⭐⭐⭐ What You Build |
| **User Experience** | ⭐⭐⭐ Good | ⭐⭐⭐⭐⭐ Optimized for Your Users |
| **Maintenance** | ⭐⭐⭐⭐⭐ Stripe Handles | ⭐⭐ Ongoing Development |

### Hybrid Approach (Recommended)

Your codebase implements a hybrid approach:

```typescript
// components/billing/HybridBillingInterface.tsx
export function HybridBillingInterface({ subscription }: { subscription: any }) {
  return (
    <div className="space-y-6">
      {/* Custom plan management */}
      <div className="bg-white rounded-lg border p-6">
        <h3 className="text-lg font-medium mb-4">Plan Management</h3>
        <CustomPlanControls subscription={subscription} />
      </div>

      {/* Custom usage dashboard */}
      <div className="bg-white rounded-lg border p-6">
        <h3 className="text-lg font-medium mb-4">Usage This Month</h3>
        <CustomUsageDashboard userId={subscription.user_id} />
      </div>

      {/* Portal for payment/invoice management */}
      <div className="bg-white rounded-lg border p-6">
        <h3 className="text-lg font-medium mb-4">Payment & Invoices</h3>
        <p className="text-gray-600 mb-4">
          Manage your payment methods, view invoices, and update billing information.
        </p>
        <CustomerPortalButton variant="primary" />
      </div>

      {/* Custom cancellation flow */}
      <div className="bg-white rounded-lg border p-6">
        <h3 className="text-lg font-medium mb-4">Subscription Settings</h3>
        <CustomCancellationControls subscription={subscription} />
      </div>
    </div>
  )
}
```

## Portal Event Handling

### Portal Webhook Events

```typescript
// Enhanced webhook handlers for portal events
export async function handleCustomerPortalEvents(event: any) {
  console.log('🏪 Processing customer portal event:', event.type)

  switch (event.type) {
    case 'customer.subscription.updated':
      // Handle plan changes made through portal
      await handlePortalSubscriptionUpdate(event.data.object)
      break

    case 'subscription_schedule.created':
      // Handle scheduled changes made through portal
      await handlePortalScheduleCreated(event.data.object)
      break

    case 'customer.updated':
      // Handle customer information updates
      await handlePortalCustomerUpdate(event.data.object)
      break

    default:
      console.log(`Unhandled portal event: ${event.type}`)
  }
}

async function handlePortalSubscriptionUpdate(subscription: any) {
  console.log('🏪 Processing portal subscription update')
  
  try {
    const supabase = createServerServiceRoleClient()
    
    // Check if this change came from portal
    const isPortalChange = subscription.metadata?.source === 'customer_portal'
    
    if (isPortalChange) {
      // Update database with portal change context
      const { error } = await supabase
        .from('subscriptions')
        .update({
          stripe_price_id: subscription.items.data[0].price.id,
          status: subscription.status,
          cancel_at_period_end: subscription.cancel_at_period_end,
          metadata: {
            portal_change: {
              changed_at: new Date().toISOString(),
              source: 'customer_portal',
              change_type: subscription.cancel_at_period_end ? 'cancellation' : 'plan_change'
            }
          },
          updated_at: new Date().toISOString()
        })
        .eq('stripe_subscription_id', subscription.id)

      if (error) {
        console.error('❌ Error updating portal change:', error)
      } else {
        console.log('✅ Portal subscription change recorded')
      }
    }

  } catch (error) {
    console.error('❌ Error handling portal subscription update:', error)
  }
}
```

## Testing Portal Integration

### Portal Flow Tests

```typescript
// cypress/e2e/billing/customer-portal.cy.ts
describe('Customer Portal Integration', () => {
  beforeEach(() => {
    cy.seedStarterUser({ email: 'portal-test@example.com' })
    cy.login('portal-test@example.com')
  })

  it('should open customer portal successfully', () => {
    cy.visit('/billing')

    // Click portal button
    cy.intercept('POST', '/api/billing/create-portal-session').as('createPortal')
    cy.get('[data-testid="customer-portal-button"]').click()

    cy.wait('@createPortal').then((interception) => {
      expect(interception.response?.statusCode).to.eq(200)
      expect(interception.response?.body.url).to.include('billing.stripe.com')
    })

    // Should redirect to Stripe portal
    cy.url().should('include', 'billing.stripe.com')
  })

  it('should handle portal session creation errors', () => {
    cy.intercept('POST', '/api/billing/create-portal-session', {
      statusCode: 500,
      body: { error: 'Portal creation failed' }
    }).as('createPortal')

    cy.visit('/billing')
    cy.get('[data-testid="customer-portal-button"]').click()

    cy.wait('@createPortal')

    // Should show error message
    cy.get('[data-testid="portal-error"]').should('be.visible')
    cy.get('[data-testid="portal-error"]').should('contain', 'failed')
  })
})
```

## Portal Configuration Management

### Dynamic Portal Configuration

```typescript
// lib/dynamic-portal-config.ts
export async function getPortalConfigurationForUser(
  userId: string
): Promise<string | null> {
  
  try {
    const subscription = await getSubscriptionDetails(userId)
    if (!subscription) return null

    const planConfig = getPlanConfig(subscription.plan_id)
    if (!planConfig) return null

    // Use different portal configurations based on plan
    switch (subscription.plan_id) {
      case 'free':
        return process.env.STRIPE_PORTAL_CONFIG_FREE
      
      case 'starter':
      case 'pro':
        return process.env.STRIPE_PORTAL_CONFIG_STANDARD
      
      case 'scale':
        return process.env.STRIPE_PORTAL_CONFIG_ENTERPRISE
      
      default:
        return process.env.STRIPE_PORTAL_CONFIG_DEFAULT
    }

  } catch (error) {
    console.error('Error determining portal configuration:', error)
    return null
  }
}

// Enhanced portal session creation with dynamic config
export async function createPortalSessionWithConfig(
  customerId: string,
  userId: string,
  returnUrl: string
): Promise<string> {
  
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  const configurationId = await getPortalConfigurationForUser(userId)
  
  const sessionParams: any = {
    customer: customerId,
    return_url: returnUrl
  }

  if (configurationId) {
    sessionParams.configuration = configurationId
  }

  const session = await stripe.billingPortal.sessions.create(sessionParams)
  
  return session.url
}
```

## Next Steps

In the next module, we'll cover building comprehensive billing dashboards that combine subscription, usage, and billing information.

## Key Takeaways

- Customer Portal provides rapid implementation with full features
- Custom interfaces offer complete control and brand consistency
- Hybrid approach combines benefits of both strategies
- Configure portal features to match your business needs
- Handle portal webhook events to stay synchronized
- Test portal integration thoroughly including error scenarios
- Use dynamic portal configurations for different user tiers
- Consider development resources when choosing between approaches
- Implement proper error handling for portal session creation
- Coordinate portal changes with your custom billing logic
