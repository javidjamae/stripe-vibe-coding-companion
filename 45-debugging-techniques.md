# Debugging Techniques for Billing Issues

## Overview

This module covers practical debugging techniques for Stripe billing systems, including logging strategies, debugging tools, and systematic troubleshooting approaches. Based on real-world debugging experience, we'll explore methods for quickly identifying and resolving billing issues.

## Logging Strategy (Your Actual Patterns)

### Structured Logging for Webhooks

From your actual webhook handlers:

```typescript
// Your actual logging pattern that works well
export async function handleInvoicePaymentPaid(invoice: any) {
  console.log('📝 Processing invoice_payment.paid')
  console.log('Invoice ID:', invoice.id)
  console.log('Subscription ID:', invoice.subscription)
  console.log('Amount Paid:', invoice.amount_paid)
  console.log('Currency:', invoice.currency)
  console.log('Status:', invoice.status)
  console.log('Period Start:', new Date(invoice.period_start * 1000).toISOString())
  console.log('Period End:', new Date(invoice.period_end * 1000).toISOString())

  // ... processing logic ...

  if (error) {
    console.error('❌ Error updating subscription:', error)
    return
  }

  console.log(`✅ Successfully updated subscription ${invoice.subscription} to status active`)
  console.log('Database result:', JSON.stringify(data, null, 2))
}
```

**Key Patterns from Your Code:**
- Use emojis for easy log scanning (📝, ✅, ❌)
- Log all key identifiers (Invoice ID, Subscription ID)
- Log business-relevant data (Amount, Currency, Dates)
- Log detailed results for successful operations
- Clear error indicators with context

### Enhanced Logging for APIs

```typescript
// Enhanced version of your API logging patterns
export async function debuggableAPIHandler(req: Request) {
  const requestId = crypto.randomUUID()
  const startTime = Date.now()
  
  console.log(`🚀 [${requestId}] API request started`, {
    method: req.method,
    url: req.url,
    timestamp: new Date().toISOString()
  })

  try {
    const body = await req.json()
    console.log(`📥 [${requestId}] Request body:`, JSON.stringify(body, null, 2))

    // Your actual processing logic
    const result = await processRequest(body)
    
    const duration = Date.now() - startTime
    console.log(`✅ [${requestId}] Request completed successfully in ${duration}ms`)
    console.log(`📤 [${requestId}] Response:`, JSON.stringify(result, null, 2))

    return new Response(JSON.stringify(result))

  } catch (error) {
    const duration = Date.now() - startTime
    console.error(`❌ [${requestId}] Request failed after ${duration}ms`)
    console.error(`💥 [${requestId}] Error:`, error)
    console.error(`📚 [${requestId}] Stack trace:`, error.stack)

    return new Response(
      JSON.stringify({ 
        error: error.message,
        requestId // Include for support requests
      }), 
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

## Database Debugging Techniques

### Your Database Query Patterns

```bash
# Your actual database debugging commands
# Check user subscription status
PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U postgres -d postgres -q -t -c "
SELECT 
  u.email,
  s.plan_id,
  s.status,
  s.stripe_subscription_id,
  s.cancel_at_period_end,
  s.current_period_end
FROM auth.users u 
JOIN public.subscriptions s ON u.id = s.user_id 
WHERE u.email = 'user@example.com';
"

# Check recent webhook events
PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U postgres -d postgres -q -t -c "
SELECT 
  event_type,
  status,
  processed_at,
  error_message
FROM webhook_events 
ORDER BY processed_at DESC 
LIMIT 10;
"

# Check usage for billing period
PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U postgres -d postgres -q -t -c "
SELECT 
  metric,
  SUM(amount) as total_usage,
  COUNT(*) as usage_count
FROM usage_ledger 
WHERE user_id = 'user-uuid-here'
AND created_at >= '2024-01-01'
GROUP BY metric;
"
```

### Database State Investigation

```typescript
// Database debugging functions
export class DatabaseDebugger {
  async investigateUser(email: string) {
    console.log(`🔍 Investigating user: ${email}`)

    const supabase = createServerServiceRoleClient()

    try {
      // 1. Check auth user
      const { data: authUsers } = await supabase.auth.admin.listUsers()
      const authUser = authUsers.users.find(u => u.email === email)
      
      console.log('Auth user:', authUser ? {
        id: authUser.id,
        email: authUser.email,
        emailConfirmed: authUser.email_confirmed_at ? 'Yes' : 'No',
        createdAt: authUser.created_at
      } : 'Not found')

      if (!authUser) return

      // 2. Check user profile
      const { data: profile, error: profileError } = await supabase
        .from('users')
        .select('*')
        .eq('id', authUser.id)
        .single()

      console.log('User profile:', profile ? {
        id: profile.id,
        email: profile.email,
        firstName: profile.first_name,
        lastName: profile.last_name
      } : `Not found (Error: ${profileError?.message})`)

      // 3. Check subscriptions
      const { data: subscriptions, error: subError } = await supabase
        .from('subscriptions')
        .select('*')
        .eq('user_id', authUser.id)

      console.log('Subscriptions:', subscriptions ? 
        subscriptions.map(sub => ({
          id: sub.id,
          planId: sub.plan_id,
          status: sub.status,
          stripeSubscriptionId: sub.stripe_subscription_id,
          cancelAtPeriodEnd: sub.cancel_at_period_end,
          metadata: sub.metadata
        })) : `Not found (Error: ${subError?.message})`)

      // 4. Check usage
      const { data: usage } = await supabase
        .from('usage_ledger')
        .select('metric, amount, created_at')
        .eq('user_id', authUser.id)
        .order('created_at', { ascending: false })
        .limit(10)

      console.log('Recent usage:', usage?.map(u => ({
        metric: u.metric,
        amount: u.amount,
        date: u.created_at
      })) || [])

    } catch (error) {
      console.error('Investigation failed:', error)
    }
  }

  async compareWithStripe(userId: string) {
    console.log(`🔄 Comparing database with Stripe for user ${userId}`)

    try {
      // Get database subscription
      const subscription = await getSubscriptionDetails(userId)
      if (!subscription) {
        console.log('❌ No subscription in database')
        return
      }

      console.log('Database subscription:', {
        planId: subscription.planId,
        status: subscription.status,
        stripeSubscriptionId: subscription.stripeSubscriptionId,
        cancelAtPeriodEnd: subscription.cancelAtPeriodEnd
      })

      if (!subscription.stripeSubscriptionId) {
        console.log('⚠️ No Stripe subscription linked')
        return
      }

      // Get Stripe subscription
      const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
        apiVersion: '2025-08-27.basil'
      })

      const stripeSub = await stripe.subscriptions.retrieve(subscription.stripeSubscriptionId)
      
      console.log('Stripe subscription:', {
        id: stripeSub.id,
        status: stripeSub.status,
        cancelAtPeriodEnd: stripeSub.cancel_at_period_end,
        currentPeriodStart: new Date(stripeSub.current_period_start * 1000).toISOString(),
        currentPeriodEnd: new Date(stripeSub.current_period_end * 1000).toISOString(),
        priceId: stripeSub.items.data[0]?.price?.id
      })

      // Identify differences
      const differences = []
      
      if (stripeSub.status !== subscription.status) {
        differences.push(`Status: DB=${subscription.status}, Stripe=${stripeSub.status}`)
      }

      if (stripeSub.cancel_at_period_end !== subscription.cancelAtPeriodEnd) {
        differences.push(`Cancel flag: DB=${subscription.cancelAtPeriodEnd}, Stripe=${stripeSub.cancel_at_period_end}`)
      }

      if (differences.length > 0) {
        console.warn('⚠️ Differences found:', differences)
        console.log('💡 Consider running reconciliation')
      } else {
        console.log('✅ Database and Stripe are in sync')
      }

    } catch (error) {
      console.error('❌ Comparison failed:', error)
    }
  }
}
```

## Stripe Dashboard Investigation

### Using Stripe Dashboard for Debugging

```typescript
// Guide for investigating issues in Stripe Dashboard
export const StripeDashboardDebugging = {
  // Steps for investigating subscription issues
  subscriptionInvestigation: [
    '1. Go to Stripe Dashboard → Customers',
    '2. Search by customer email or ID',
    '3. Check customer\'s subscription tab',
    '4. Look at subscription timeline for events',
    '5. Check invoices tab for payment history',
    '6. Review events tab for webhook deliveries'
  ],

  // What to look for in subscription timeline
  subscriptionTimelineClues: [
    'subscription.created - When subscription started',
    'subscription.updated - Plan changes, status changes',
    'invoice.payment_succeeded - Successful payments',
    'invoice.payment_failed - Failed payments',
    'subscription_schedule.created - Scheduled changes'
  ],

  // Webhook delivery investigation
  webhookDebugging: [
    '1. Go to Stripe Dashboard → Developers → Webhooks',
    '2. Click on your webhook endpoint',
    '3. Check "Recent deliveries" section',
    '4. Look for failed deliveries (red indicators)',
    '5. Click on specific event to see response',
    '6. Check response body and status code'
  ]
}
```

### Stripe Event Timeline Analysis

```typescript
// Analyze Stripe events for debugging
export async function analyzeStripeEvents(customerId: string, hours: number = 24) {
  console.log(`📊 Analyzing Stripe events for customer ${customerId} (last ${hours}h)`)

  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  try {
    const since = Math.floor((Date.now() - hours * 60 * 60 * 1000) / 1000)

    // Get events for this customer
    const events = await stripe.events.list({
      created: { gte: since },
      limit: 100
    })

    // Filter events related to this customer
    const customerEvents = events.data.filter(event => {
      const obj = event.data.object as any
      return obj.customer === customerId ||
             obj.subscription?.customer === customerId ||
             obj.id === customerId
    })

    console.log(`Found ${customerEvents.length} events for customer`)

    // Group by event type
    const eventsByType = customerEvents.reduce((acc, event) => {
      if (!acc[event.type]) {
        acc[event.type] = []
      }
      acc[event.type].push({
        id: event.id,
        created: new Date(event.created * 1000).toISOString(),
        data: event.data.object
      })
      return acc
    }, {} as Record<string, any[]>)

    // Display timeline
    Object.entries(eventsByType).forEach(([eventType, events]) => {
      console.log(`\n📅 ${eventType} (${events.length} events):`)
      events.forEach(event => {
        console.log(`  ${event.created}: ${event.id}`)
      })
    })

    return eventsByType

  } catch (error) {
    console.error('Event analysis failed:', error)
    return {}
  }
}
```

## Local Development Debugging

### Debug Mode Configuration

```typescript
// Enhanced debugging for development
export const DebugConfig = {
  isDebugMode: process.env.NODE_ENV === 'development' && process.env.DEBUG_BILLING === 'true',

  log: (message: string, data?: any) => {
    if (DebugConfig.isDebugMode) {
      console.log(`🐛 DEBUG: ${message}`, data ? JSON.stringify(data, null, 2) : '')
    }
  },

  error: (message: string, error: any) => {
    if (DebugConfig.isDebugMode) {
      console.error(`🐛 DEBUG ERROR: ${message}`)
      console.error('Error details:', error)
      console.error('Stack trace:', error.stack)
    }
  },

  time: (label: string) => {
    if (DebugConfig.isDebugMode) {
      console.time(`🐛 DEBUG TIME: ${label}`)
    }
  },

  timeEnd: (label: string) => {
    if (DebugConfig.isDebugMode) {
      console.timeEnd(`🐛 DEBUG TIME: ${label}`)
    }
  }
}

// Usage in your API handlers
export async function POST(req: Request) {
  DebugConfig.time('Upgrade API')
  DebugConfig.log('Upgrade request started', { url: req.url })

  try {
    const body = await req.json()
    DebugConfig.log('Request body received', body)

    const result = await processUpgrade(body)
    DebugConfig.log('Upgrade processing completed', result)

    DebugConfig.timeEnd('Upgrade API')
    return new Response(JSON.stringify(result))

  } catch (error) {
    DebugConfig.error('Upgrade failed', error)
    DebugConfig.timeEnd('Upgrade API')
    throw error
  }
}
```

## Webhook Debugging Tools

### Webhook Event Inspector

```typescript
// Debug webhook events systematically
export class WebhookDebugger {
  async inspectWebhookEvent(eventId: string) {
    console.log(`🔍 Inspecting webhook event: ${eventId}`)

    try {
      const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
        apiVersion: '2025-08-27.basil'
      })

      // Get event from Stripe
      const event = await stripe.events.retrieve(eventId)
      
      console.log('Event details:', {
        id: event.id,
        type: event.type,
        created: new Date(event.created * 1000).toISOString(),
        livemode: event.livemode,
        apiVersion: event.api_version
      })

      // Inspect the object
      const obj = event.data.object as any
      console.log('Event object:', {
        objectType: obj.object,
        objectId: obj.id,
        status: obj.status,
        customer: obj.customer,
        subscription: obj.subscription
      })

      // Check if we processed this event
      const supabase = createServerServiceRoleClient()
      const { data: processedEvent } = await supabase
        .from('webhook_events')
        .select('*')
        .eq('event_id', eventId)
        .single()

      if (processedEvent) {
        console.log('Processing record:', {
          status: processedEvent.status,
          processedAt: processedEvent.processed_at,
          duration: processedEvent.duration_ms,
          error: processedEvent.error_message
        })
      } else {
        console.log('⚠️ Event not found in processing log')
      }

      // Simulate processing to see what would happen
      console.log('\n🧪 Simulating event processing...')
      await this.simulateEventProcessing(event)

    } catch (error) {
      console.error('Event inspection failed:', error)
    }
  }

  private async simulateEventProcessing(event: any) {
    try {
      // Import your actual handlers
      const handlers = await import('../app/api/webhooks/stripe/handlers')
      
      switch (event.type) {
        case 'invoice.payment_succeeded':
          console.log('🧪 Simulating invoice.payment_succeeded')
          await handlers.handleInvoicePaymentPaid(event.data.object)
          break

        case 'subscription_schedule.created':
          console.log('🧪 Simulating subscription_schedule.created')
          await handlers.handleSubscriptionScheduleCreated(event.data.object)
          break

        case 'subscription_schedule.released':
          console.log('🧪 Simulating subscription_schedule.released')
          await handlers.handleSubscriptionScheduleReleased(event.data.object)
          break

        default:
          console.log(`🧪 No handler for event type: ${event.type}`)
      }

      console.log('✅ Simulation completed successfully')

    } catch (error) {
      console.error('❌ Simulation failed:', error)
    }
  }
}
```

## API Debugging Tools

### Request/Response Debugging

```typescript
// Debug API calls with detailed logging
export class APIDebugger {
  static async debugStripeCall<T>(
    operation: string,
    stripeCall: () => Promise<T>
  ): Promise<T> {
    const startTime = Date.now()
    console.log(`🔌 Stripe API: ${operation} started`)

    try {
      const result = await stripeCall()
      const duration = Date.now() - startTime
      
      console.log(`✅ Stripe API: ${operation} completed in ${duration}ms`)
      DebugConfig.log(`Stripe ${operation} result`, result)

      return result

    } catch (error) {
      const duration = Date.now() - startTime
      console.error(`❌ Stripe API: ${operation} failed after ${duration}ms`)
      
      if (error.type === 'StripeCardError') {
        console.error('Card Error:', {
          code: error.code,
          message: error.message,
          declineCode: error.decline_code
        })
      } else if (error.type === 'StripeInvalidRequestError') {
        console.error('Invalid Request:', {
          message: error.message,
          param: error.param
        })
      }

      throw error
    }
  }

  static async debugDatabaseCall<T>(
    operation: string,
    dbCall: () => Promise<T>
  ): Promise<T> {
    const startTime = Date.now()
    console.log(`🗄️ Database: ${operation} started`)

    try {
      const result = await dbCall()
      const duration = Date.now() - startTime
      
      console.log(`✅ Database: ${operation} completed in ${duration}ms`)
      DebugConfig.log(`Database ${operation} result`, result)

      return result

    } catch (error) {
      const duration = Date.now() - startTime
      console.error(`❌ Database: ${operation} failed after ${duration}ms`)
      console.error('Database error:', error)

      throw error
    }
  }
}

// Usage in your APIs
export async function upgradeSubscription(userId: string, newPlanId: string) {
  // Debug database call
  const subscription = await APIDebugger.debugDatabaseCall(
    'get subscription',
    () => getSubscriptionDetails(userId)
  )

  if (!subscription) {
    throw new Error('No subscription found')
  }

  // Debug Stripe call
  const updatedSub = await APIDebugger.debugStripeCall(
    'update subscription',
    () => stripe.subscriptions.update(subscription.stripeSubscriptionId, {
      items: [{ id: itemId, price: newPriceId }],
      proration_behavior: 'create_prorations'
    })
  )

  return updatedSub
}
```

## Test Environment Debugging

### Cypress Debugging Helpers

```typescript
// Enhanced Cypress debugging for your test patterns
export const CypressDebugHelpers = {
  // Debug test user state
  debugTestUser: (email: string) => {
    cy.task('debugTestUser', email).then((result: any) => {
      cy.log('Test user debug result:', result)
    })
  },

  // Debug API responses
  debugAPICall: (alias: string) => {
    cy.wait(alias).then((interception) => {
      cy.log('API Call Debug:', {
        url: interception.request.url,
        method: interception.request.method,
        body: interception.request.body,
        status: interception.response?.statusCode,
        response: interception.response?.body
      })
    })
  },

  // Debug database state
  debugDatabaseState: (email: string) => {
    cy.task('getSubscriptionForEmail', email).then((result: any) => {
      cy.log('Database state:', result)
    })

    cy.task('getStripeCancelFlagForEmail', email).then((result: any) => {
      cy.log('Stripe cancel flag:', result)
    })
  },

  // Debug authentication state
  debugAuthState: () => {
    cy.visit('/test/auth-bridge')
    cy.get('[data-testid="auth-bridge-status"]').then(($el) => {
      cy.log('Auth bridge status:', $el.text())
    })
  }
}

// Usage in tests
describe('Billing Flow Debug', () => {
  const email = `debug-test-${Date.now()}@example.com`

  it('should debug complete billing flow', () => {
    cy.task('seedStarterUserWithStripeSubscription', { email })
    
    // Debug initial state
    CypressDebugHelpers.debugTestUser(email)
    CypressDebugHelpers.debugDatabaseState(email)
    
    cy.login(email)
    
    // Debug auth state
    CypressDebugHelpers.debugAuthState()
    
    cy.visit('/billing')
    
    // Debug upgrade flow
    cy.intercept('POST', '/api/billing/upgrade').as('upgrade')
    cy.get('[data-testid="pro-action-button"]').click()
    cy.get('[data-testid="confirm-upgrade-button"]').click()
    
    // Debug API call
    CypressDebugHelpers.debugAPICall('@upgrade')
    
    // Debug final state
    CypressDebugHelpers.debugDatabaseState(email)
  })
})
```

## Production Debugging

### Safe Production Debugging

```typescript
// Safe debugging tools for production
export class ProductionDebugger {
  // Read-only operations safe for production
  async safeInvestigation(userId: string) {
    console.log(`🔍 Safe production investigation for user ${userId}`)

    try {
      // Only read operations - no modifications
      const subscription = await getSubscriptionDetails(userId)
      const usage = await getUsageInfo(userId)

      // Log sanitized information (no sensitive data)
      console.log('User state summary:', {
        hasSubscription: !!subscription,
        planId: subscription?.planId,
        status: subscription?.status,
        billingInterval: subscription?.billingInterval,
        usageThisPeriod: usage?.currentPeriodMinutes,
        planLimit: usage?.planLimit,
        canMakeRequest: usage?.canMakeRequest
      })

      // Check for common issues
      const issues = []
      
      if (subscription && !subscription.stripeSubscriptionId) {
        issues.push('Subscription not linked to Stripe')
      }

      if (subscription?.status === 'past_due') {
        issues.push('Subscription is past due')
      }

      if (usage && usage.currentPeriodMinutes > usage.planLimit) {
        issues.push('Usage exceeds plan limit')
      }

      if (issues.length > 0) {
        console.warn('⚠️ Issues detected:', issues)
      } else {
        console.log('✅ No obvious issues detected')
      }

    } catch (error) {
      console.error('❌ Safe investigation failed:', error)
    }
  }

  // Emergency read-only health check
  async emergencyHealthCheck() {
    console.log('🚨 Emergency health check')

    const checks = {
      database: false,
      stripe: false,
      webhooks: false
    }

    try {
      // Test database connectivity
      const supabase = createServerServiceRoleClient()
      const { error: dbError } = await supabase
        .from('subscriptions')
        .select('id')
        .limit(1)

      checks.database = !dbError
      console.log(`Database: ${checks.database ? '✅' : '❌'}`)

      // Test Stripe connectivity
      const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
        apiVersion: '2025-08-27.basil'
      })

      await stripe.customers.list({ limit: 1 })
      checks.stripe = true
      console.log('Stripe API: ✅')

      // Check recent webhook processing
      const { data: recentWebhooks } = await supabase
        .from('webhook_events')
        .select('status')
        .gte('processed_at', new Date(Date.now() - 60 * 60 * 1000).toISOString()) // Last hour
        .limit(10)

      const failedWebhooks = recentWebhooks?.filter(w => w.status === 'failed').length || 0
      checks.webhooks = failedWebhooks < 5 // Less than 5 failures in last hour
      console.log(`Webhooks: ${checks.webhooks ? '✅' : '❌'} (${failedWebhooks} failures in last hour)`)

    } catch (error) {
      console.error('Health check failed:', error)
    }

    const overall = checks.database && checks.stripe && checks.webhooks
    console.log(`\n🏥 Overall health: ${overall ? '✅ HEALTHY' : '❌ ISSUES DETECTED'}`)

    return checks
  }
}
```

## Debugging Checklist

### Systematic Debugging Approach

```typescript
// Step-by-step debugging checklist
export const DebuggingChecklist = {
  // For subscription issues
  subscriptionIssues: [
    '1. Verify user authentication is working',
    '2. Check if user exists in database',
    '3. Check if subscription exists in database',
    '4. Verify Stripe subscription exists and matches',
    '5. Compare database and Stripe status',
    '6. Check recent webhook events',
    '7. Validate plan configuration',
    '8. Test with known working user'
  ],

  // For webhook issues
  webhookIssues: [
    '1. Check webhook endpoint is accessible',
    '2. Verify webhook secret is correct',
    '3. Test signature verification with sample event',
    '4. Check recent webhook deliveries in Stripe',
    '5. Review webhook processing logs',
    '6. Test webhook handler with mock data',
    '7. Verify database permissions for webhook operations'
  ],

  // For API issues
  apiIssues: [
    '1. Test API endpoint with curl/Postman',
    '2. Verify authentication headers',
    '3. Check request body format',
    '4. Review API logs for errors',
    '5. Test with minimal request data',
    '6. Verify database connectivity',
    '7. Check Stripe API connectivity',
    '8. Test with known working data'
  ]
}
```

### Debug Information Collection

```typescript
// Collect comprehensive debug information
export async function collectDebugInfo(userId: string) {
  console.log(`📋 Collecting debug information for user ${userId}`)

  const debugInfo = {
    timestamp: new Date().toISOString(),
    environment: process.env.NODE_ENV,
    stripeMode: process.env.STRIPE_SECRET_KEY?.startsWith('sk_test_') ? 'test' : 'live',
    user: null as any,
    subscription: null as any,
    usage: null as any,
    recentWebhooks: [] as any[],
    recentAPIErrors: [] as any[]
  }

  try {
    // Collect user data
    const supabase = createServerServiceRoleClient()
    
    const { data: user } = await supabase.auth.admin.getUserById(userId)
    debugInfo.user = user.user ? {
      id: user.user.id,
      email: user.user.email,
      emailConfirmed: !!user.user.email_confirmed_at,
      createdAt: user.user.created_at
    } : null

    // Collect subscription data
    debugInfo.subscription = await getSubscriptionDetails(userId)

    // Collect usage data
    debugInfo.usage = await getUsageInfo(userId)

    // Collect recent webhook events
    const { data: webhooks } = await supabase
      .from('webhook_events')
      .select('event_type, status, processed_at, error_message')
      .order('processed_at', { ascending: false })
      .limit(20)

    debugInfo.recentWebhooks = webhooks || []

    // Collect recent API errors
    const { data: errors } = await supabase
      .from('api_error_log')
      .select('endpoint, error_message, timestamp')
      .gte('timestamp', new Date(Date.now() - 24 * 60 * 60 * 1000).toISOString())
      .order('timestamp', { ascending: false })
      .limit(10)

    debugInfo.recentAPIErrors = errors || []

    console.log('✅ Debug information collected')
    return debugInfo

  } catch (error) {
    console.error('❌ Debug information collection failed:', error)
    debugInfo.recentAPIErrors.push({
      endpoint: 'debug_collection',
      error_message: error.message,
      timestamp: new Date().toISOString()
    })
    
    return debugInfo
  }
}
```

## Remote Debugging Tools

### Support Debug Endpoint

```typescript
// app/api/debug/user/route.ts (Only enable in development/staging)
export async function POST(request: Request) {
  // Only allow in non-production environments
  if (process.env.NODE_ENV === 'production') {
    return new Response(
      JSON.stringify({ error: 'Debug endpoint not available in production' }),
      { status: 403 }
    )
  }

  try {
    const { userId, email } = await request.json()
    
    if (!userId && !email) {
      return new Response(
        JSON.stringify({ error: 'userId or email required' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    let targetUserId = userId

    // Look up user by email if needed
    if (!targetUserId && email) {
      const { data: user } = await supabase.auth.admin.listUsers()
      const foundUser = user.users.find(u => u.email === email)
      targetUserId = foundUser?.id
    }

    if (!targetUserId) {
      return new Response(
        JSON.stringify({ error: 'User not found' }),
        { status: 404 }
      )
    }

    // Collect debug information
    const debugInfo = await collectDebugInfo(targetUserId)

    return new Response(JSON.stringify({
      success: true,
      debugInfo
    }))

  } catch (error) {
    console.error('Debug endpoint error:', error)
    return new Response(
      JSON.stringify({ error: 'Debug collection failed' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}
```

## Log Analysis Tools

### Log Pattern Analysis

```bash
#!/bin/bash
# Analyze logs for billing issues

echo "🔍 Analyzing billing logs..."

# Find recent billing errors
echo "Recent billing errors:"
grep -n "❌.*billing\|❌.*stripe\|❌.*subscription" /var/log/app.log | tail -20

# Find webhook processing issues
echo -e "\nWebhook processing issues:"
grep -n "❌.*webhook\|❌.*invoice\|❌.*schedule" /var/log/app.log | tail -20

# Find authentication failures
echo -e "\nAuthentication failures:"
grep -n "❌.*auth\|❌.*unauthorized\|❌.*401" /var/log/app.log | tail -20

# Find slow operations
echo -e "\nSlow operations (>5s):"
grep -n "completed in [5-9][0-9][0-9][0-9]ms\|completed in [0-9][0-9][0-9][0-9][0-9]ms" /var/log/app.log | tail -10

echo "✅ Log analysis completed"
```

### Real-Time Log Monitoring

```bash
#!/bin/bash
# Monitor billing operations in real-time

echo "👀 Monitoring billing operations..."
echo "Press Ctrl+C to stop"

# Monitor billing-related logs in real-time
tail -f /var/log/app.log | grep --line-buffered "📝\|✅\|❌\|🚀\|💳\|📅" | while read line; do
  timestamp=$(date '+%H:%M:%S')
  echo "[$timestamp] $line"
done
```

## Alternative: Minimal Debugging Setup

For simpler debugging needs:

### Basic Error Logging

```typescript
// lib/debug/simple-logger.ts (Alternative approach)
export class SimpleLogger {
  static logError(operation: string, error: any, context: any = {}) {
    console.error(`❌ ${operation} failed:`, {
      error: error.message,
      context,
      timestamp: new Date().toISOString(),
      stack: error.stack
    })
  }

  static logSuccess(operation: string, result: any = {}) {
    console.log(`✅ ${operation} succeeded:`, {
      result,
      timestamp: new Date().toISOString()
    })
  }

  static logWarning(operation: string, message: string, context: any = {}) {
    console.warn(`⚠️ ${operation} warning: ${message}`, {
      context,
      timestamp: new Date().toISOString()
    })
  }
}

// Usage
try {
  const result = await upgradeSubscription(userId, newPlanId)
  SimpleLogger.logSuccess('Subscription upgrade', { userId, newPlanId })
  return result
} catch (error) {
  SimpleLogger.logError('Subscription upgrade', error, { userId, newPlanId })
  throw error
}
```

## Next Steps

In the next module, we'll cover data reconciliation strategies for keeping your database in sync with Stripe.

## Key Takeaways

- **Use structured logging** with clear indicators (emojis, prefixes)
- **Log all key identifiers** (user ID, subscription ID, invoice ID)
- **Debug systematically** using checklists and step-by-step approaches
- **Compare database and Stripe state** to identify inconsistencies
- **Use debug modes** in development for detailed logging
- **Collect comprehensive debug information** for support cases
- **Test debugging tools** in staging before using in production
- **Monitor logs in real-time** during critical operations
- **Implement safe production debugging** with read-only operations
- **Document common issues** and their solutions for team knowledge
