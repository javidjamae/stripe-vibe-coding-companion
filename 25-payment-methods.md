# Payment Methods via Customer Portal

## Overview

This module covers how your codebase handles payment methods through Stripe's Customer Portal. Your implementation takes a portal-first approach rather than building custom payment method management APIs.

## Your Codebase's Approach

Your actual implementation manages payment methods through:

1. **Stripe Customer Portal**: Primary interface for payment method updates
2. **Seed Helpers**: Creating test payment methods for Cypress tests  
3. **Webhook Handlers**: Processing payment-related events
4. **Portal Integration**: Simple API to create portal sessions

## Customer Portal Integration (Your Actual Implementation)

### Portal Session Creation API

Our recommended approach based on your actual implementation:

```typescript
// billing/create-portal-session.ts - Framework-agnostic portal session creation
import { createCustomerPortalSession, BillingDependencies } from './lib/billing'

export async function handleCreatePortalSession(request: Request): Promise<Response> {
  try {
    const { userId } = await request.json()
    
    if (!userId) {
      return new Response(
        JSON.stringify({ error: 'User ID is required' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }
    
    // Create Supabase client for server-side operations
    const supabase = createClient(
      process.env.SUPABASE_URL!,
      process.env.SUPABASE_SERVICE_ROLE_KEY!
    )
    
    // Use framework-agnostic billing functions
    const dependencies: BillingDependencies = {
      supabase: createSupabaseClient(),
      stripeSecretKey: process.env.STRIPE_SECRET_KEY!,
      getPlanConfig: (planId) => getPlanConfig(planId),
      getAllPlans: () => getAllPlans()
    }

    // Create the customer portal session
    const returnUrl = `${process.env.APP_URL}/billing`
    console.log('Portal session return URL:', returnUrl)
    const session = await createCustomerPortalSession({
      userId,
      returnUrl
    }, dependencies)
    
    return new Response(
      JSON.stringify(session),
      { headers: { 'Content-Type': 'application/json' } }
    )
  } catch (error) {
    console.error('Error creating customer portal session:', error)
    return new Response(
      JSON.stringify({ error: error instanceof Error ? error.message : 'Failed to create customer portal session' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

**Key Points from Your Implementation**:
- Uses `userId` in request body (not user context from auth)
- Uses service role client to verify user exists
- Delegates to `createCustomerPortalSession` function in `@/lib/billing`
- Returns to `/billing` page after portal session

### Customer Portal Session Function (Your Actual Implementation)

From your actual code in `lib/billing.ts`:

```typescript
// Your actual createCustomerPortalSession implementation
export async function createCustomerPortalSession(userId: string, returnUrl: string, supabaseClient?: any): Promise<{ url: string }> {
  try {
    // Get the user's subscription details to find their Stripe customer ID
    const subscription = await getSubscriptionDetails(userId, supabaseClient)
    
    if (!subscription || !subscription.stripeCustomerId) {
      throw new Error('No active subscription found for user')
    }
    
    // Import Stripe dynamically to avoid issues in test environment
    const Stripe = (await import('stripe')).default
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })
    
    // Create a customer portal session
    const session = await stripe.billingPortal.sessions.create({
      customer: subscription.stripeCustomerId,
      return_url: returnUrl,
    })

    return { url: session.url }
  } catch (error) {
    console.error('Error creating customer portal session:', error)
    throw error
  }
}
```

**Key Patterns from Your Code**:
- Gets customer ID from `getSubscriptionDetails(userId)`
- Uses dynamic Stripe import "to avoid issues in test environment"
- Simple portal session creation with just customer and return_url
- No custom portal configuration (uses Stripe defaults)

## Test Payment Method Creation (Your Actual Pattern)

From your Cypress seed helpers:

```typescript
// Your actual test payment method creation pattern
export async function seedStarterUserWithStripeSubscription(email: string) {
  // ... user creation code ...

  // Create Stripe customer
  const customer = await stripe.customers.create({ 
    email: email,
    name: 'Test User',
    metadata: {
      userId: userId,
      test_source: 'cypress'
    }
  })

  // Create Stripe subscription with payment_behavior to handle payment
  const subscription = await stripe.subscriptions.create({
    customer: customer.id,
    items: [{
      price: 'price_1S1EmGHxCxqKRRWFzsKZxGSY' // Starter monthly price
    }],
    metadata: {
      userId: userId,
      planId: 'starter',
      test_source: 'cypress'
    }
    // Note: In test mode, Stripe handles payment methods automatically
  })

  // ... rest of subscription creation
}
```

**Key Patterns from Your Test Code**:
- Creates customer and subscription in Stripe test mode
- Relies on Stripe's test mode default payment handling
- Uses metadata to track test source and user relationships
- Focuses on subscription creation rather than payment method management

## Frontend Integration (Your Actual Implementation)

### Manage Payment Button

From your actual billing page implementation:

```typescript
// Your actual "Manage Payment" button from billing page
{!currentPlan?.isFree && (
  <button
    onClick={handleBillingPortal}
    disabled={processing}
    className="px-4 py-2 bg-blue-600 text-white rounded-md hover:bg-blue-700 disabled:opacity-50 min-w-[140px] text-center flex-shrink-0"
  >
    {processing ? 'Loading...' : 'Manage Payment'}
  </button>
)}

// Your actual handleBillingPortal function
const handleBillingPortal = async () => {
  if (!user) return
  
  try {
    setProcessing(true)
    
    // Call the server-side API to create the customer portal session
    const response = await fetch('/api/billing/create-portal-session', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        userId: user.id,
      }),
    })

    if (!response.ok) {
      const errorData = await response.json()
      throw new Error(errorData.error || 'Failed to create customer portal session')
    }

    const session = await response.json()

    // Redirect to Stripe customer portal
    window.location.href = session.url
  } catch (error) {
    console.error('Error creating portal session:', error)
    alert('Failed to access billing portal. Please try again.')
  } finally {
    setProcessing(false)
  }
}
```

**Key Patterns from Your UI Code**:
- Simple button that only appears for paid plans (`!currentPlan?.isFree`)
- Uses `window.location.href` for redirect (not new tab)
- Passes `userId` in request body to API
- Basic error handling with alert (could be improved with toast)

## Why Customer Portal? (Your Approach)

Your codebase uses the Customer Portal approach because:

1. **Rapid Implementation**: No custom payment UI needed
2. **PCI Compliance**: Stripe handles all sensitive payment data
3. **Feature Complete**: Payment methods, invoices, billing info all included
4. **Mobile Optimized**: Works perfectly on all devices
5. **Security**: Enterprise-grade security handled by Stripe
6. **Maintenance Free**: Stripe updates and maintains the interface

## Testing Portal Integration (Your Actual Tests)

From your Cypress tests:

```typescript
// Your actual portal test from billing-paid-user.cy.ts
it('should redirect to Stripe customer portal when Manage Payment is clicked', () => {
  cy.visit('/billing')
  
  // Wait for the page to load and check if we have a paid plan
  cy.get('[data-testid="current-plan-section"]').should('be.visible')
  
  // Intercept portal session creation and assert success
  cy.intercept('POST', '/api/billing/create-portal-session').as('portal')

  // Click Manage Payment (should trigger portal session)
  cy.get('[data-testid="current-plan-section"]').within(() => {
    cy.get('button').contains('Manage Payment').should('be.visible').click()
  })

  // Assert the API request succeeds
  cy.wait('@portal').its('response.statusCode').should('eq', 200)
})
```

**Your Test Patterns**:
- Tests portal session creation API call
- Verifies button is visible for paid users
- Uses intercepts to assert API success
- Doesn't test actual Stripe portal (external service)

## Alternative: Custom Payment Method APIs

If you wanted to build custom payment method management instead of using the portal, here's how you could implement it:

### List Payment Methods API (Alternative Approach)

If you wanted to build custom payment method management instead of using the Customer Portal:

```typescript
// billing/payment-methods.ts (Alternative approach - not used in our implementation)
export async function handleGetPaymentMethods(request: Request): Promise<Response> {
  try {
    // Extract user context (implementation varies by framework)
    const user = await getUserFromRequest(request)
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Get customer ID from subscription
    const { data: subscription } = await supabase
      .from('subscriptions')
      .select('stripe_customer_id')
      .eq('user_id', user.id)
      .single()

    if (!subscription?.stripe_customer_id) {
      return new Response(
      JSON.stringify({ error: 'No customer found' ),
      { status: 404 })
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Get payment methods
    const paymentMethods = await stripe.paymentMethods.list({
      customer: subscription.stripe_customer_id,
      type: 'card'
    })

    // Get default payment method
    const customer = await stripe.customers.retrieve(subscription.stripe_customer_id)
    const defaultPaymentMethod = (customer as any).invoice_settings?.default_payment_method

    return new Response(
      JSON.stringify({
        paymentMethods: paymentMethods.data,
        defaultPaymentMethod
      }),
      { headers: { 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('List payment methods error:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to load payment methods' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

### Add Payment Method API

```typescript
// billing/add-payment-method.ts (Alternative approach - not used in our implementation)
export async function handleAddPaymentMethod(request: Request): Promise<Response> {
  try {
    // Extract user context (implementation varies by framework)
    const user = await getUserFromRequest(request)
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const { paymentMethodId, setAsDefault = false } = await request.json()

    if (!paymentMethodId) {
      return new Response(
        JSON.stringify({ error: 'Missing paymentMethodId' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Get customer ID
    const supabase = createSupabaseClient()
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

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Attach payment method to customer
    await stripe.paymentMethods.attach(paymentMethodId, {
      customer: subscription.stripe_customer_id,
    })

    // Set as default if requested
    if (setAsDefault) {
      await stripe.customers.update(subscription.stripe_customer_id, {
        invoice_settings: {
          default_payment_method: paymentMethodId
        }
      })
    }

    return new Response(
      JSON.stringify({
        success: true,
        message: 'Payment method added successfully'
      }),
      { headers: { 'Content-Type': 'application/json' } }
    )

  } catch (error) {
    console.error('Add payment method error:', error)
    
    if (error instanceof Stripe.errors.StripeError) {
      return new Response(
        JSON.stringify({ 
          error: error.message,
          code: error.code 
        }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    return new Response(
      JSON.stringify({ error: 'Failed to add payment method' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

### Custom Payment Method UI Component

```typescript
// components/billing/PaymentMethodManager.tsx (Alternative approach)
import { useState, useEffect } from 'react'
import { CreditCardIcon, PlusIcon, TrashIcon } from '@heroicons/react/24/outline'

export function PaymentMethodManager() {
  const [paymentMethods, setPaymentMethods] = useState<any[]>([])
  const [defaultPaymentMethod, setDefaultPaymentMethod] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    loadPaymentMethods()
  }, [])

  const loadPaymentMethods = async () => {
    setLoading(true)
    try {
      const response = await fetch('/api/billing/payment-methods')
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

  const handleSetDefault = async (paymentMethodId: string) => {
    try {
      const response = await fetch('/api/billing/payment-methods/set-default', {
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

  if (loading) {
    return <div className="animate-pulse bg-gray-200 rounded-lg h-64 w-full"></div>
  }

  return (
    <div>
      <div className="flex justify-between items-center mb-6">
        <h3 className="text-lg font-medium text-gray-900">Payment Methods</h3>
        <button className="bg-blue-600 text-white px-4 py-2 rounded-md hover:bg-blue-700 inline-flex items-center">
          <PlusIcon className="h-4 w-4 mr-2" />
          Add Card
        </button>
      </div>

      {paymentMethods.length === 0 ? (
        <div className="text-center py-8 bg-gray-50 rounded-lg">
          <CreditCardIcon className="h-12 w-12 text-gray-400 mx-auto mb-4" />
          <p className="text-gray-600 mb-4">No payment methods on file</p>
        </div>
      ) : (
        <div className="space-y-4">
          {paymentMethods.map((pm) => (
            <div key={pm.id} className="border rounded-lg p-4 flex items-center justify-between">
              <div className="flex items-center">
                <CreditCardIcon className="h-6 w-6 text-gray-400 mr-3" />
                <div>
                  <p className="font-medium">•••• •••• •••• {pm.card?.last4}</p>
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
              
              <div className="flex items-center space-x-2">
                {defaultPaymentMethod !== pm.id && (
                  <button
                    onClick={() => handleSetDefault(pm.id)}
                    className="text-sm text-blue-600 hover:text-blue-700 px-3 py-1 rounded border border-blue-200 hover:bg-blue-50"
                  >
                    Set Default
                  </button>
                )}
                
                <button className="text-sm text-red-600 hover:text-red-700 p-1 rounded hover:bg-red-50">
                  <TrashIcon className="h-4 w-4" />
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

## Portal vs Custom: When to Choose Each

### Use Customer Portal (Your Approach) When:
- **MVP/Early Stage**: Need billing features quickly
- **Limited Resources**: Small development team
- **Standard Needs**: Common subscription operations
- **Compliance Focus**: Want Stripe to handle PCI compliance
- **Maintenance Averse**: Don't want to maintain payment UI

### Use Custom APIs When:
- **Brand Consistency**: Need UI to match your design system
- **Custom Workflows**: Unique business logic or flows
- **Enhanced UX**: Want streamlined in-app experience
- **Advanced Features**: Need features not in portal
- **Data Integration**: Combine billing with other app data

## Next Steps

In the next module, we'll cover webhook security patterns and signature verification best practices.

## Key Takeaways

- **Your codebase uses Customer Portal** for payment method management
- **Portal approach** provides rapid implementation with full PCI compliance
- **Simple API pattern**: userId → subscription → customer → portal session
- **Test portal integration** by verifying API calls, not external portal
- **Custom APIs are possible** but require more development and maintenance
- **Choose based on resources**: Portal for speed, custom for control
- **Dynamic Stripe imports** help avoid test environment issues
- **Service role client** needed for user verification in portal API

## Alternative: Payment Failure Handling

While your codebase uses the Customer Portal for payment method management, you might want to handle payment failures in your app. Here's how you could implement payment failure handling:

### Payment Failure Webhook Handler

```typescript
// Enhanced webhook handler for payment failures (not in your current codebase)
export async function handleInvoicePaymentFailed(invoice: any) {
  console.log('💳 Processing invoice.payment_failed')
  console.log('Invoice ID:', invoice.id)
  console.log('Subscription ID:', invoice.subscription)
  console.log('Attempt Count:', invoice.attempt_count)

  if (!invoice.subscription) {
    console.log('❌ No subscription ID found')
    return
  }

  try {
    const supabase = createServerServiceRoleClient()
    
    // Update subscription status to past_due
    const { data: subscription, error } = await supabase
      .from('subscriptions')
      .update({
        status: 'past_due',
        metadata: {
          payment_failure: {
            invoice_id: invoice.id,
            attempt_count: invoice.attempt_count,
            failure_reason: invoice.last_finalization_error?.message || 'Payment failed',
            failed_at: new Date().toISOString()
          }
        },
        updated_at: new Date().toISOString()
      })
      .eq('stripe_subscription_id', invoice.subscription)
      .select()
      .single()

    if (error) {
      console.error('❌ Error updating subscription status:', error)
      return
    }

    console.log('✅ Payment failure processed')
    return subscription

  } catch (error) {
    console.error('❌ Exception in handleInvoicePaymentFailed:', error)
  }
}
```

### Payment Recovery Banner UI

```typescript
// components/billing/PaymentRecoveryBanner.tsx (Alternative approach)
import { ExclamationTriangleIcon } from '@heroicons/react/24/outline'

export function PaymentRecoveryBanner({ subscription }: { subscription: any }) {
  if (subscription?.status !== 'past_due' && subscription?.status !== 'unpaid') {
    return null
  }

  const paymentFailure = subscription.metadata?.payment_failure
  const attemptCount = paymentFailure?.attempt_count || 0

  return (
    <div className="bg-red-50 border border-red-200 rounded-lg p-4 mb-6">
      <div className="flex items-start">
        <ExclamationTriangleIcon className="h-5 w-5 text-red-400 mt-0.5 mr-3" />
        
        <div className="flex-1">
          <h4 className="font-medium text-red-800 mb-1">Payment Failed</h4>
          <p className="text-sm text-red-700 mb-3">
            Your payment could not be processed.
            {attemptCount > 1 && ` (Attempt ${attemptCount} of 4)`}
          </p>
          
          <button
            onClick={() => {
              // Open Customer Portal for payment method update
              window.location.href = '/billing?action=manage-payment'
            }}
            className="bg-red-600 text-white px-4 py-2 rounded-md text-sm hover:bg-red-700"
          >
            Update Payment Method
          </button>
        </div>
      </div>
    </div>
  )
}
```

## Next Steps

In the next module, we'll cover webhook security patterns and signature verification best practices.

## Key Takeaways

- **Customer Portal is the recommended approach** for payment method management
- **Portal provides** PCI compliance, security, and comprehensive features
- **Simple integration pattern**: userId → subscription → customer → portal session
- **Test portal integration** by verifying API calls work correctly
- **Custom payment APIs** are possible but require significant additional development
- **Payment failure handling** can be enhanced with custom webhook logic
- **Dynamic Stripe imports** help avoid test environment issues
- **Hybrid approach** combines portal benefits with custom UI where needed
