# Common Stripe Integration Issues and Solutions

## Overview

This module covers the most common issues encountered when implementing Stripe billing systems, their root causes, and proven solutions. Based on real-world troubleshooting experience, we'll explore debugging strategies and preventive measures.

## Authentication and Authorization Issues

### Issue: "Unauthorized" Errors in API Calls

**Symptoms:**
- API calls return 401 Unauthorized
- User appears logged in but billing APIs fail
- Inconsistent authentication behavior

**Root Causes:**
```typescript
// Common authentication problems
const authIssues = [
  'JWT token expired or invalid',
  'User context not properly set in Supabase client',
  'RLS policies blocking legitimate access',
  'Service role vs user context confusion',
  'Missing authentication headers'
]
```

**Solution Pattern (From Your Codebase):**
```typescript
// Your actual authentication pattern that works
export async function POST(req: Request) {
  try {
    const supabase = createServerUserClient()
    
    // Always check user authentication first
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    if (authError || !user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }), 
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Use user.id for all subsequent operations
    const subscription = await getSubscriptionDetails(user.id)
    
    // ... rest of API logic
  } catch (error) {
    console.error('Authentication error:', error)
    return new Response(
      JSON.stringify({ error: 'Authentication failed' }), 
      { status: 401, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

**Prevention:**
- Always validate user authentication at the start of API handlers
- Use consistent Supabase client creation patterns
- Test authentication with real user tokens
- Log authentication failures for debugging

### Issue: RLS Policy Blocks Legitimate Access

**Symptoms:**
- Database queries return empty results
- User can't access their own subscription data
- "No subscription found" errors for existing subscriptions

**Root Cause:**
```sql
-- Problem: RLS policy too restrictive or user context missing
CREATE POLICY "Users can view subscriptions" ON subscriptions
  FOR SELECT USING (auth.uid() = user_id);
-- This fails if auth.uid() is null
```

**Solution:**
```typescript
// Ensure user context is set before database queries
const supabase = createServerUserClient() // Not service role!

// Set user session if needed
if (userToken) {
  await supabase.auth.setSession({
    access_token: userToken,
    refresh_token: ''
  })
}

// Now RLS policies will work correctly
const { data: subscription } = await supabase
  .from('subscriptions')
  .select('*')
  .eq('user_id', userId) // This will be validated by RLS
  .single()
```

## Stripe API Issues

### Issue: "No such subscription" Errors

**Symptoms:**
- Stripe API returns subscription not found
- Database has subscription ID but Stripe doesn't
- Upgrade/downgrade operations fail

**Root Causes:**
```typescript
const subscriptionIssues = [
  'Subscription was cancelled in Stripe but not in database',
  'Test mode vs live mode data mismatch',
  'Subscription ID format corruption',
  'Race condition between webhook and API call',
  'Subscription created in different Stripe account'
]
```

**Debugging Steps:**
```typescript
// Debug subscription existence
export async function debugSubscription(subscriptionId: string) {
  console.log(`🔍 Debugging subscription: ${subscriptionId}`)

  try {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Check if subscription exists in Stripe
    const stripeSubscription = await stripe.subscriptions.retrieve(subscriptionId)
    console.log('✅ Stripe subscription found:', {
      id: stripeSubscription.id,
      status: stripeSubscription.status,
      customer: stripeSubscription.customer,
      created: new Date(stripeSubscription.created * 1000).toISOString()
    })

    // Check database record
    const supabase = createServerServiceRoleClient()
    const { data: dbSubscription } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('stripe_subscription_id', subscriptionId)
      .single()

    if (dbSubscription) {
      console.log('✅ Database subscription found:', {
        id: dbSubscription.id,
        userId: dbSubscription.user_id,
        planId: dbSubscription.plan_id,
        status: dbSubscription.status
      })

      // Check for inconsistencies
      if (stripeSubscription.status !== dbSubscription.status) {
        console.warn('⚠️ Status mismatch:', {
          stripe: stripeSubscription.status,
          database: dbSubscription.status
        })
      }
    } else {
      console.error('❌ Database subscription not found')
    }

  } catch (error) {
    console.error('❌ Subscription debug failed:', error)
    
    if (error.code === 'resource_missing') {
      console.error('💡 Subscription does not exist in Stripe')
    }
  }
}
```

**Solution:**
```typescript
// Robust subscription retrieval with fallbacks
export async function getSubscriptionSafely(userId: string) {
  try {
    // Try RPC function first (your pattern)
    const { data, error } = await supabase
      .rpc('get_user_active_subscription', { user_uuid: userId })

    if (error || !data || data.length === 0) {
      // Fallback to direct table query
      const { data: fallback } = await supabase
        .from('subscriptions')
        .select('*')
        .eq('user_id', userId)
        .order('updated_at', { ascending: false })
        .limit(1)
        .single()

      return fallback
    }

    return data[0]

  } catch (error) {
    console.error('Subscription retrieval failed:', error)
    return null
  }
}
```

### Issue: Webhook Signature Verification Failures

**Symptoms:**
- All webhooks fail with "Invalid signature"
- Webhook endpoint returns 400 errors
- Stripe shows webhook delivery failures

**Root Causes:**
```typescript
const webhookIssues = [
  'Wrong webhook secret (test vs live)',
  'Body parsing corrupts raw webhook data',
  'Missing stripe-signature header',
  'Incorrect signature construction',
  'Clock skew between servers'
]
```

**Solution (Your Working Pattern):**
```typescript
// Your actual webhook signature verification that works
export async function POST(request: Request) {
  try {
    const body = await request.text() // Important: get raw text, not JSON
    const signature = request.headers.get('stripe-signature')

    if (!signature) {
      return new Response(
        JSON.stringify({ error: 'Missing stripe-signature header' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    // Verify webhook signature
    const event = stripe.webhooks.constructEvent(body, signature, webhookSecret)
    
    // Process event only after verification
    await processWebhookEvent(event)
    
    return new Response(JSON.stringify({ received: true }))

  } catch (err) {
    console.error('❌ Webhook signature verification failed:', err)
    return new Response(
      JSON.stringify({ error: 'Invalid signature' }),
      { status: 400, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

**Prevention:**
- Always use `request.text()` for webhook body, never `request.json()`
- Verify webhook secret matches Stripe dashboard
- Test webhook signature verification in development
- Use Stripe CLI for local webhook testing

## Database Synchronization Issues

### Issue: Database Out of Sync with Stripe

**Symptoms:**
- UI shows wrong subscription status
- Database status doesn't match Stripe
- Billing operations fail due to stale data

**Debugging Your Database State:**
```bash
# Your actual database debugging pattern
PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U postgres -d postgres -q -t -c "
SELECT 
  u.email,
  s.plan_id,
  s.status as db_status,
  s.stripe_subscription_id,
  s.current_period_end
FROM auth.users u 
JOIN public.subscriptions s ON u.id = s.user_id 
WHERE u.email = 'test-user@example.com';
"
```

**Solution Pattern:**
```typescript
// Reconciliation function to sync database with Stripe
export async function reconcileSubscription(userId: string) {
  console.log(`🔄 Reconciling subscription for user ${userId}`)

  try {
    const supabase = createServerServiceRoleClient()
    
    // Get database subscription
    const { data: dbSubscription } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('user_id', userId)
      .single()

    if (!dbSubscription?.stripe_subscription_id) {
      console.log('No Stripe subscription to reconcile')
      return
    }

    // Get Stripe subscription
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    const stripeSubscription = await stripe.subscriptions.retrieve(
      dbSubscription.stripe_subscription_id
    )

    // Compare and update differences
    const updates: any = {}
    
    if (stripeSubscription.status !== dbSubscription.status) {
      updates.status = stripeSubscription.status
      console.log(`Status sync: ${dbSubscription.status} → ${stripeSubscription.status}`)
    }

    if (stripeSubscription.cancel_at_period_end !== dbSubscription.cancel_at_period_end) {
      updates.cancel_at_period_end = stripeSubscription.cancel_at_period_end
      console.log(`Cancel flag sync: ${dbSubscription.cancel_at_period_end} → ${stripeSubscription.cancel_at_period_end}`)
    }

    const stripePeriodStart = new Date(stripeSubscription.current_period_start * 1000).toISOString()
    const stripePeriodEnd = new Date(stripeSubscription.current_period_end * 1000).toISOString()

    if (stripePeriodStart !== dbSubscription.current_period_start) {
      updates.current_period_start = stripePeriodStart
    }

    if (stripePeriodEnd !== dbSubscription.current_period_end) {
      updates.current_period_end = stripePeriodEnd
    }

    // Apply updates if any
    if (Object.keys(updates).length > 0) {
      updates.updated_at = new Date().toISOString()
      
      const { error } = await supabase
        .from('subscriptions')
        .update(updates)
        .eq('id', dbSubscription.id)

      if (error) {
        console.error('Reconciliation update failed:', error)
      } else {
        console.log(`✅ Reconciled ${Object.keys(updates).length} fields`)
      }
    } else {
      console.log('✅ Subscription already in sync')
    }

  } catch (error) {
    console.error('❌ Subscription reconciliation failed:', error)
  }
}
```

## Plan Configuration Issues

### Issue: Invalid Price IDs

**Symptoms:**
- "No such price" errors from Stripe
- Checkout sessions fail to create
- Plan upgrades fail

**Root Causes:**
```typescript
const priceIDIssues = [
  'Price ID doesn\'t exist in current Stripe mode (test vs live)',
  'Typo in price ID configuration',
  'Price ID from different Stripe account',
  'Price was deleted or archived in Stripe',
  'Wrong billing interval mapping'
]
```

**Debugging Your Plan Configuration:**
```typescript
// Debug plan configuration against Stripe
export async function validatePlanConfiguration() {
  console.log('🔍 Validating plan configuration against Stripe...')

  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  const plans = getAllPlans() // Your actual plan config
  const issues: string[] = []

  for (const [planId, config] of Object.entries(plans)) {
    console.log(`Checking plan: ${planId}`)

    // Validate monthly price ID
    if (config.monthly?.stripePriceId) {
      try {
        const price = await stripe.prices.retrieve(config.monthly.stripePriceId)
        console.log(`✅ Monthly price valid: ${config.monthly.stripePriceId}`)
        
        // Verify price matches configuration
        if (price.unit_amount !== config.monthly.priceCents) {
          issues.push(`Price mismatch for ${planId} monthly: Stripe=${price.unit_amount}, Config=${config.monthly.priceCents}`)
        }
      } catch (error) {
        issues.push(`Invalid monthly price ID for ${planId}: ${config.monthly.stripePriceId}`)
      }
    }

    // Validate annual price ID
    if (config.annual?.stripePriceId) {
      try {
        const price = await stripe.prices.retrieve(config.annual.stripePriceId)
        console.log(`✅ Annual price valid: ${config.annual.stripePriceId}`)
        
        if (price.unit_amount !== config.annual.priceCents) {
          issues.push(`Price mismatch for ${planId} annual: Stripe=${price.unit_amount}, Config=${config.annual.priceCents}`)
        }
      } catch (error) {
        issues.push(`Invalid annual price ID for ${planId}: ${config.annual.stripePriceId}`)
      }
    }
  }

  return {
    valid: issues.length === 0,
    issues
  }
}
```

## Webhook Processing Issues

### Issue: Webhook Events Not Processing

**Symptoms:**
- Webhooks are received but subscription status doesn't update
- Database remains out of sync with Stripe
- No error logs in webhook processing

**Common Problems:**
```typescript
// Your webhook handler debugging pattern
export async function handleInvoicePaymentPaid(invoice: any) {
  console.log('📝 Processing invoice_payment.paid')
  console.log('Invoice ID:', invoice.id)
  console.log('Subscription ID:', invoice.subscription)

  // Common issue: Missing subscription ID
  if (!invoice.subscription) {
    console.log('❌ No subscription ID found in invoice')
    return // This is correct - early return prevents errors
  }

  try {
    // Common issue: Wrong Supabase client context
    const supabase = createServerServiceRoleClient() // Service role for webhooks!
    
    // Common issue: Wrong field mapping
    const { data, error } = await supabase
      .from('subscriptions')
      .update({
        status: 'active',
        current_period_start: new Date(invoice.period_start * 1000).toISOString(), // Convert epoch to ISO
        current_period_end: new Date(invoice.period_end * 1000).toISOString(),
        updated_at: new Date().toISOString()
      })
      .eq('stripe_subscription_id', invoice.subscription) // Match on Stripe ID
      .select()
      .single()

    if (error) {
      console.error('❌ Error updating subscription:', error)
      return
    }

    console.log(`✅ Successfully updated subscription ${invoice.subscription}`)
    
  } catch (error) {
    console.error('❌ Exception in handleInvoicePaymentPaid:', error)
    // Don't throw - this would cause Stripe to retry
  }
}
```

**Prevention:**
- Use service role client for webhook operations
- Always convert Stripe epoch timestamps to ISO strings
- Handle missing data gracefully with early returns
- Log all webhook processing steps for debugging

### Issue: Webhook Retry Loops

**Symptoms:**
- Same webhook event processed multiple times
- Duplicate database updates
- Stripe shows repeated webhook deliveries

**Solution:**
```typescript
// Implement webhook idempotency
export async function processWebhookEvent(event: any) {
  const supabase = createServerServiceRoleClient()

  // Check if event already processed
  const { data: existingEvent } = await supabase
    .from('webhook_events')
    .select('event_id')
    .eq('event_id', event.id)
    .single()

  if (existingEvent) {
    console.log(`⚠️ Duplicate webhook event: ${event.id}`)
    return { received: true, duplicate: true }
  }

  // Record event processing
  await supabase
    .from('webhook_events')
    .insert({
      event_id: event.id,
      event_type: event.type,
      status: 'processing',
      processed_at: new Date().toISOString()
    })

  try {
    // Process the event
    await handleWebhookEvent(event)

    // Mark as completed
    await supabase
      .from('webhook_events')
      .update({ status: 'completed' })
      .eq('event_id', event.id)

  } catch (error) {
    // Mark as failed
    await supabase
      .from('webhook_events')
      .update({ 
        status: 'failed',
        error_message: error.message 
      })
      .eq('event_id', event.id)

    throw error // Let Stripe retry
  }
}
```

## Subscription State Issues

### Issue: Subscription Status Inconsistencies

**Symptoms:**
- UI shows wrong subscription status
- User can't upgrade/downgrade when they should be able to
- Billing operations fail with status errors

**Your Status Debugging Pattern:**
```typescript
// Debug subscription status across systems
export async function debugSubscriptionStatus(userId: string) {
  console.log(`🔍 Debugging subscription status for user ${userId}`)

  try {
    // Check database status
    const { data: dbSub } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('user_id', userId)
      .single()

    console.log('Database subscription:', {
      id: dbSub?.id,
      status: dbSub?.status,
      planId: dbSub?.plan_id,
      cancelAtPeriodEnd: dbSub?.cancel_at_period_end,
      stripeSubscriptionId: dbSub?.stripe_subscription_id
    })

    // Check Stripe status if linked
    if (dbSub?.stripe_subscription_id) {
      const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
        apiVersion: '2025-08-27.basil'
      })

      const stripeSub = await stripe.subscriptions.retrieve(dbSub.stripe_subscription_id)
      
      console.log('Stripe subscription:', {
        id: stripeSub.id,
        status: stripeSub.status,
        cancelAtPeriodEnd: stripeSub.cancel_at_period_end,
        currentPeriodEnd: new Date(stripeSub.current_period_end * 1000).toISOString()
      })

      // Check for inconsistencies
      const inconsistencies = []
      
      if (stripeSub.status !== dbSub.status) {
        inconsistencies.push(`Status: DB=${dbSub.status}, Stripe=${stripeSub.status}`)
      }

      if (stripeSub.cancel_at_period_end !== dbSub.cancel_at_period_end) {
        inconsistencies.push(`Cancel flag: DB=${dbSub.cancel_at_period_end}, Stripe=${stripeSub.cancel_at_period_end}`)
      }

      if (inconsistencies.length > 0) {
        console.warn('⚠️ Inconsistencies found:', inconsistencies)
        
        // Offer to reconcile
        console.log('💡 Run reconcileSubscription() to fix inconsistencies')
      } else {
        console.log('✅ Database and Stripe are in sync')
      }
    }

  } catch (error) {
    console.error('❌ Status debugging failed:', error)
  }
}
```

## Proration and Billing Issues

### Issue: Unexpected Proration Amounts

**Symptoms:**
- Customers charged more/less than expected on upgrades
- Proration preview doesn't match actual charge
- Negative proration amounts

**Understanding Proration (Your Implementation):**
```typescript
// Your actual proration preview implementation
export async function getProrationPreview(userId: string, newPriceId: string) {
  try {
    const subscription = await getSubscriptionDetails(userId)
    if (!subscription?.stripe_subscription_id) {
      throw new Error('No active subscription found')
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    const current = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
    const currentItem = current.items?.data?.[0]
    
    if (!currentItem) {
      throw new Error('No subscription item found')
    }

    // Preview with proration
    const preview = await stripe.invoices.retrieveUpcoming({
      customer: (current.customer as string),
      subscription: current.id,
      subscription_items: [
        { id: currentItem.id, price: newPriceId }
      ],
      subscription_proration_behavior: 'create_prorations'
    })

    const amountDue = (preview.amount_due ?? 0) / 100
    const currency = (preview.currency || 'usd').toUpperCase()

    console.log('Proration preview:', {
      currentPrice: currentItem.price.id,
      newPrice: newPriceId,
      amountDue,
      currency,
      periodStart: new Date(current.current_period_start * 1000).toISOString(),
      periodEnd: new Date(current.current_period_end * 1000).toISOString()
    })

    return { amountDue, currency }

  } catch (error) {
    console.error('Proration preview failed:', error)
    throw error
  }
}
```

**Common Proration Issues:**
```typescript
const prorationIssues = {
  // Issue: Proration calculated incorrectly
  incorrectCalculation: {
    cause: 'Wrong billing_cycle_anchor setting',
    solution: 'Use billing_cycle_anchor: "unchanged" for upgrades'
  },

  // Issue: Negative proration (credit)
  negativeProration: {
    cause: 'Downgrade with immediate proration',
    solution: 'Use cancel_at_period_end for downgrades'
  },

  // Issue: No proration when expected
  noProration: {
    cause: 'proration_behavior set to "none"',
    solution: 'Use proration_behavior: "create_prorations" for upgrades'
  }
}
```

## Environment and Configuration Issues

### Issue: Test vs Production Data Mixing

**Symptoms:**
- Test customers appear in production
- Live transactions in test environment
- Wrong Stripe mode for environment

**Prevention (Your Patterns):**
```typescript
// Environment validation on startup
export function validateEnvironment() {
  const stripeKey = process.env.STRIPE_SECRET_KEY
  const environment = process.env.NODE_ENV

  // Validate key format
  if (!stripeKey?.startsWith('sk_test_') && !stripeKey?.startsWith('sk_live_')) {
    throw new Error('Invalid Stripe key format')
  }

  // Validate environment consistency
  if (environment === 'production' && stripeKey.startsWith('sk_test_')) {
    throw new Error('Production environment cannot use test Stripe keys')
  }

  if (environment !== 'production' && stripeKey.startsWith('sk_live_')) {
    console.warn('⚠️ Using live Stripe keys in non-production environment')
  }

  console.log(`✅ Environment validated: ${environment} with ${stripeKey.startsWith('sk_test_') ? 'test' : 'live'} Stripe keys`)
}
```

### Issue: Missing Environment Variables

**Symptoms:**
- Application crashes on startup
- "undefined" errors in Stripe operations
- Webhook signature verification fails

**Solution:**
```typescript
// Environment variable validation
export function validateRequiredEnvVars() {
  const required = [
    'STRIPE_SECRET_KEY',
    'STRIPE_WEBHOOK_SECRET',
    'SUPABASE_URL',
    'SUPABASE_SERVICE_ROLE_KEY'
  ]

  const missing = required.filter(varName => !process.env[varName])
  
  if (missing.length > 0) {
    console.error('❌ Missing required environment variables:')
    missing.forEach(varName => console.error(`  - ${varName}`))
    throw new Error(`Missing environment variables: ${missing.join(', ')}`)
  }

  console.log('✅ All required environment variables present')
}
```

## Testing and Development Issues

### Issue: Tests Failing Due to Async Operations

**Symptoms:**
- Intermittent test failures
- Database operations not completing before assertions
- Race conditions in test setup

**Solution (Your Test Patterns):**
```typescript
// Your actual test pattern with proper async handling
describe('Billing API', () => {
  beforeEach(async () => {
    // Ensure test data is fully created before test runs
    const result = await cy.task('seedStarterUserWithStripeSubscription', { email })
    expect(result.ok).to.be.true
    
    // Wait for authentication to be established
    cy.request({
      method: 'POST',
      url: '/api/test/login',
      body: { email, password: 'TestPassword123!' }
    }).should('have.property', 'status', 200)

    // Visit auth bridge and wait for it to be ready
    cy.visit('/test/auth-bridge')
    cy.get('[data-testid="auth-bridge-status"]').should('contain', 'ok')
    cy.wait(1000) // Give auth bridge time to complete
  })
})
```

### Issue: Test Data Pollution

**Symptoms:**
- Tests pass individually but fail when run together
- Unexpected data in test database
- Flaky test results

**Solution:**
```typescript
// Test isolation pattern
describe('Isolated Billing Tests', () => {
  const email = `test-${Date.now()}@example.com` // Unique per test run

  beforeEach(() => {
    // Clear any existing session
    cy.clearCookies()
    cy.clearLocalStorage()
    
    // Create fresh test data
    cy.task('seedStarterUserWithStripeSubscription', { email })
  })

  afterEach(() => {
    // Clean up test data
    cy.task('cleanupTestUser', { email })
  })
})
```

## Performance Issues

### Issue: Slow API Response Times

**Symptoms:**
- Billing APIs take >5 seconds to respond
- Checkout session creation times out
- Database queries are slow

**Debugging:**
```typescript
// Performance monitoring for your APIs
export async function POST(req: Request) {
  const startTime = Date.now()
  const requestId = crypto.randomUUID()
  
  console.log(`🚀 [${requestId}] API request started`)

  try {
    // Your actual API logic
    const result = await processUpgrade(/* ... */)
    
    const duration = Date.now() - startTime
    console.log(`✅ [${requestId}] API completed in ${duration}ms`)
    
    // Alert on slow responses
    if (duration > 5000) {
      console.warn(`⚠️ Slow API response: ${duration}ms`)
    }

    return new Response(JSON.stringify(result))

  } catch (error) {
    const duration = Date.now() - startTime
    console.error(`❌ [${requestId}] API failed after ${duration}ms:`, error)
    throw error
  }
}
```

**Common Performance Solutions:**
```typescript
const performanceOptimizations = {
  // Cache plan configuration
  cachePlanConfig: 'Cache getAllPlans() result in memory',
  
  // Use RPC functions for complex queries
  useRPC: 'Use get_user_active_subscription RPC instead of complex joins',
  
  // Batch Stripe API calls
  batchAPICalls: 'Combine multiple Stripe operations where possible',
  
  // Index database properly
  addIndexes: 'Ensure indexes on user_id, stripe_subscription_id',
  
  // Connection pooling
  connectionPooling: 'Use connection pooling for database'
}
```

## Error Recovery Patterns

### Graceful Error Handling

```typescript
// Your error handling patterns that work
export async function handleUpgradeWithRecovery(userId: string, newPlanId: string) {
  try {
    // Attempt upgrade
    return await upgradeSubscription(userId, newPlanId)

  } catch (error) {
    console.error('Upgrade failed:', error)

    // Specific error recovery
    if (error.code === 'resource_missing') {
      // Subscription doesn't exist - try to reconcile
      await reconcileSubscription(userId)
      
      // Retry once after reconciliation
      try {
        return await upgradeSubscription(userId, newPlanId)
      } catch (retryError) {
        console.error('Upgrade retry failed:', retryError)
        throw new Error('Subscription not found after reconciliation')
      }
    }

    if (error.code === 'card_declined') {
      // Payment method issue - provide clear guidance
      throw new Error('Payment method was declined. Please update your payment method and try again.')
    }

    // Generic error handling
    throw new Error('Upgrade failed. Please try again or contact support.')
  }
}
```

## Debugging Tools and Techniques

### Subscription Health Check

```typescript
// Comprehensive subscription health check
export async function checkSubscriptionHealth(userId: string) {
  console.log(`🏥 Health check for user ${userId}`)

  const issues: string[] = []
  const warnings: string[] = []

  try {
    // 1. Check user exists
    const { data: user } = await supabase.auth.admin.getUserById(userId)
    if (!user.user) {
      issues.push('User not found in auth system')
      return { healthy: false, issues, warnings }
    }

    // 2. Check user profile
    const { data: profile } = await supabase
      .from('users')
      .select('*')
      .eq('id', userId)
      .single()

    if (!profile) {
      issues.push('User profile not found')
    }

    // 3. Check subscription
    const subscription = await getSubscriptionDetails(userId)
    if (!subscription) {
      warnings.push('No subscription found (user may be on free plan)')
    } else {
      // 4. Check Stripe subscription if linked
      if (subscription.stripe_subscription_id) {
        try {
          const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
            apiVersion: '2025-08-27.basil'
          })
          
          const stripeSub = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
          
          // Check for inconsistencies
          if (stripeSub.status !== subscription.status) {
            issues.push(`Status mismatch: DB=${subscription.status}, Stripe=${stripeSub.status}`)
          }

          if (stripeSub.cancel_at_period_end !== subscription.cancelAtPeriodEnd) {
            issues.push(`Cancel flag mismatch: DB=${subscription.cancelAtPeriodEnd}, Stripe=${stripeSub.cancel_at_period_end}`)
          }

        } catch (stripeError) {
          issues.push(`Stripe subscription not found: ${subscription.stripe_subscription_id}`)
        }
      }

      // 5. Check plan configuration
      const planConfig = getPlanConfig(subscription.plan_id)
      if (!planConfig) {
        issues.push(`Invalid plan configuration: ${subscription.plan_id}`)
      }
    }

    const healthy = issues.length === 0

    console.log(`${healthy ? '✅' : '❌'} Health check completed`)
    if (issues.length > 0) {
      console.log('Issues:', issues)
    }
    if (warnings.length > 0) {
      console.log('Warnings:', warnings)
    }

    return { healthy, issues, warnings }

  } catch (error) {
    console.error('Health check failed:', error)
    return { 
      healthy: false, 
      issues: ['Health check failed to complete'], 
      warnings: [] 
    }
  }
}
```

## Quick Fix Commands

### Emergency Reconciliation

```bash
#!/bin/bash
# Emergency subscription reconciliation script

echo "🚨 Emergency subscription reconciliation"

# Get user ID from email
USER_ID=$(PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U postgres -d postgres -q -t -c "
SELECT id FROM auth.users WHERE email = '$1';
" | xargs)

if [ -z "$USER_ID" ]; then
  echo "❌ User not found: $1"
  exit 1
fi

echo "Found user ID: $USER_ID"

# Check subscription status
PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U postgres -d postgres -q -t -c "
SELECT 
  s.plan_id,
  s.status,
  s.stripe_subscription_id,
  s.cancel_at_period_end
FROM public.subscriptions s 
WHERE s.user_id = '$USER_ID';
"

echo "💡 Run reconcileSubscription('$USER_ID') to fix any inconsistencies"
```

## Next Steps

In the next module, we'll cover debugging techniques and tools for troubleshooting billing issues.

## Key Takeaways

- **Always validate authentication** at the start of API handlers
- **Use service role client** for webhook operations, user client for API operations
- **Handle missing data gracefully** with early returns and clear error messages
- **Implement webhook idempotency** to prevent duplicate processing
- **Validate environment configuration** on application startup
- **Use consistent error handling patterns** across all billing operations
- **Debug subscription state** by comparing database and Stripe data
- **Test with realistic data** and proper async handling
- **Monitor API performance** and alert on slow responses
- **Implement health checks** for proactive issue detection
