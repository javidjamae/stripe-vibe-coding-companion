# Integration Testing with Real Stripe Data

## Overview

This module covers integration testing patterns for Stripe billing systems, including testing with real Stripe test data, database interactions, and end-to-end API flows. Based on your codebase's testing philosophy, integration tests use real services.

## Integration Testing Philosophy

From your codebase rules:

> **Integration tests must use the real database** (no mocks)
> **RLS and constraints must be verified** via integration tests

### Why Real Services Matter

1. **RLS Verification**: Mocks cannot test Row Level Security policies
2. **Constraint Testing**: Database constraints and triggers need real DB
3. **API Behavior**: Stripe API behavior changes and edge cases
4. **Transaction Handling**: Real transaction behavior and rollbacks
5. **Performance Testing**: Real query performance and optimization

## Integration Test Setup

### Test Environment Configuration

```typescript
// __tests__/integration/setup.ts
import { createClient } from '@supabase/supabase-js'
import Stripe from 'stripe'

// Integration test environment
export const testSupabase = createClient(
  process.env.TEST_SUPABASE_URL!,
  process.env.TEST_SUPABASE_SERVICE_ROLE_KEY!
)

export const testStripe = new Stripe(process.env.STRIPE_TEST_SECRET_KEY!, {
  apiVersion: '2025-08-27.basil'
})

// Test database setup
export async function setupIntegrationTestDatabase() {
  console.log('🔧 Setting up integration test database')
  
  try {
    // Run migrations
    await testSupabase.rpc('reset_test_schema')
    
    // Create test users
    const testUsers = await createTestUsers()
    
    // Create test Stripe customers and subscriptions
    const testSubscriptions = await createTestStripeData(testUsers)
    
    console.log('✅ Integration test database ready')
    return { testUsers, testSubscriptions }

  } catch (error) {
    console.error('❌ Integration test setup failed:', error)
    throw error
  }
}

export async function cleanupIntegrationTestDatabase() {
  console.log('🧹 Cleaning up integration test database')
  
  try {
    // Clean up Stripe test data
    await cleanupStripeTestData()
    
    // Clean up database
    await testSupabase.rpc('cleanup_test_data')
    
    console.log('✅ Integration test cleanup complete')

  } catch (error) {
    console.error('❌ Integration test cleanup failed:', error)
  }
}

async function createTestUsers() {
  const users = [
    {
      id: 'user_integration_free',
      email: 'free-integration@test.com',
      first_name: 'Free',
      last_name: 'User'
    },
    {
      id: 'user_integration_starter',
      email: 'starter-integration@test.com',
      first_name: 'Starter',
      last_name: 'User'
    },
    {
      id: 'user_integration_pro',
      email: 'pro-integration@test.com',
      first_name: 'Pro',
      last_name: 'User'
    }
  ]

  for (const user of users) {
    // Create in Supabase Auth
    const { data: authUser } = await testSupabase.auth.admin.createUser({
      email: user.email,
      password: 'TestPassword123!',
      email_confirm: true,
      user_metadata: {
        first_name: user.first_name,
        last_name: user.last_name
      }
    })

    // Create in users table
    await testSupabase
      .from('users')
      .insert({
        id: authUser.user!.id,
        email: user.email,
        first_name: user.first_name,
        last_name: user.last_name
      })
  }

  return users
}

async function createTestStripeData(users: any[]) {
  const subscriptions = []

  for (const user of users.slice(1)) { // Skip free user
    // Create Stripe customer
    const customer = await testStripe.customers.create({
      email: user.email,
      name: `${user.first_name} ${user.last_name}`,
      metadata: {
        userId: user.id,
        test_source: 'integration_test'
      }
    })

    // Create subscription
    const planId = user.email.includes('starter') ? 'starter' : 'pro'
    const priceId = getStripePriceId(planId, 'month')

    const subscription = await testStripe.subscriptions.create({
      customer: customer.id,
      items: [{ price: priceId }],
      metadata: {
        userId: user.id,
        planId: planId,
        test_source: 'integration_test'
      }
    })

    // Create in database
    await testSupabase
      .from('subscriptions')
      .insert({
        user_id: user.id,
        stripe_subscription_id: subscription.id,
        stripe_customer_id: customer.id,
        stripe_price_id: priceId,
        plan_id: planId,
        status: 'active',
        current_period_start: new Date(subscription.current_period_start * 1000).toISOString(),
        current_period_end: new Date(subscription.current_period_end * 1000).toISOString()
      })

    subscriptions.push({ user, customer, subscription })
  }

  return subscriptions
}
```

## Billing Flow Integration Tests

### Subscription Creation Flow

```typescript
// __tests__/integration/subscription-creation.test.ts
import { setupIntegrationTestDatabase, cleanupIntegrationTestDatabase, testSupabase, testStripe } from './setup'
import { createCheckoutSessionForPlan } from '@/lib/billing'
import { handleCheckoutSessionCompleted } from '@/app/api/webhooks/stripe/handlers'

describe('Subscription Creation Integration', () => {
  let testData: any

  beforeAll(async () => {
    testData = await setupIntegrationTestDatabase()
  })

  afterAll(async () => {
    await cleanupIntegrationTestDatabase()
  })

  it('should create subscription end-to-end with real Stripe', async () => {
    const userId = 'user_integration_test_new'
    const email = 'new-integration@test.com'

    // Step 1: Create checkout session
    const checkoutResult = await createCheckoutSessionForPlan(
      userId,
      email,
      'starter',
      'http://localhost:3000/success',
      'http://localhost:3000/cancel'
    )

    expect(checkoutResult.url).toContain('checkout.stripe.com')

    // Step 2: Simulate checkout completion
    // In real integration test, you'd use Stripe's test completion
    const mockCheckoutSession = {
      id: 'cs_integration_test',
      customer: 'cus_integration_test',
      subscription: 'sub_integration_test',
      metadata: {
        userId: userId,
        planId: 'starter',
        billingInterval: 'month'
      }
    }

    // Create actual Stripe subscription for testing
    const customer = await testStripe.customers.create({
      email: email,
      metadata: { userId: userId }
    })

    const subscription = await testStripe.subscriptions.create({
      customer: customer.id,
      items: [{ price: getStripePriceId('starter', 'month') }],
      metadata: {
        userId: userId,
        planId: 'starter'
      }
    })

    // Update mock with real IDs
    mockCheckoutSession.customer = customer.id
    mockCheckoutSession.subscription = subscription.id

    // Step 3: Process webhook
    const result = await handleCheckoutSessionCompleted(mockCheckoutSession)

    expect(result).toBeDefined()
    expect(result.id).toBeDefined()

    // Step 4: Verify database state
    const { data: dbSubscription, error } = await testSupabase
      .from('subscriptions')
      .select('*')
      .eq('user_id', userId)
      .single()

    expect(error).toBeNull()
    expect(dbSubscription).toBeDefined()
    expect(dbSubscription.plan_id).toBe('starter')
    expect(dbSubscription.stripe_subscription_id).toBe(subscription.id)
    expect(dbSubscription.status).toBe('active')

    // Step 5: Verify Stripe state
    const stripeSubscription = await testStripe.subscriptions.retrieve(subscription.id)
    expect(stripeSubscription.status).toBe('active')
    expect(stripeSubscription.items.data[0].price.id).toBe(getStripePriceId('starter', 'month'))
  })

  it('should handle upgrade flow with real proration', async () => {
    const userId = testData.testUsers[1].id // Starter user
    
    // Get current subscription
    const { data: currentSub } = await testSupabase
      .from('subscriptions')
      .select('*')
      .eq('user_id', userId)
      .single()

    expect(currentSub).toBeDefined()

    // Perform upgrade to Pro
    const newPriceId = getStripePriceId('pro', 'month')
    const stripeSubscription = await testStripe.subscriptions.retrieve(currentSub.stripe_subscription_id)
    const subscriptionItemId = stripeSubscription.items.data[0].id

    const upgradedSubscription = await testStripe.subscriptions.update(currentSub.stripe_subscription_id, {
      items: [{
        id: subscriptionItemId,
        price: newPriceId,
      }],
      proration_behavior: 'create_prorations',
    })

    // Update database
    const { data: updatedSub, error } = await testSupabase
      .from('subscriptions')
      .update({
        stripe_price_id: newPriceId,
        plan_id: 'pro',
        status: upgradedSubscription.status,
        updated_at: new Date().toISOString()
      })
      .eq('id', currentSub.id)
      .select()
      .single()

    expect(error).toBeNull()
    expect(updatedSub.plan_id).toBe('pro')

    // Verify proration was created
    const invoices = await testStripe.invoices.list({
      customer: stripeSubscription.customer as string,
      limit: 1
    })

    expect(invoices.data.length).toBeGreaterThan(0)
    const latestInvoice = invoices.data[0]
    
    // Should have proration line items
    const prorationItems = latestInvoice.lines.data.filter(line => line.proration)
    expect(prorationItems.length).toBeGreaterThan(0)
  })
})
```

### RLS Policy Testing

```typescript
// __tests__/integration/rls-policies.test.ts
import { testSupabase } from './setup'
import { createClient } from '@supabase/supabase-js'

describe('Row Level Security Policies', () => {
  let userClient: any
  let testUserId: string

  beforeAll(async () => {
    // Create test user
    const { data: authUser } = await testSupabase.auth.admin.createUser({
      email: 'rls-test@example.com',
      password: 'TestPassword123!',
      email_confirm: true
    })

    testUserId = authUser.user!.id

    // Create user client (simulates user context)
    userClient = createClient(
      process.env.TEST_SUPABASE_URL!,
      process.env.TEST_SUPABASE_ANON_KEY!
    )

    // Sign in user
    await userClient.auth.signInWithPassword({
      email: 'rls-test@example.com',
      password: 'TestPassword123!'
    })
  })

  afterAll(async () => {
    await testSupabase.auth.admin.deleteUser(testUserId)
  })

  it('should allow users to read their own subscription', async () => {
    // Create subscription with service role
    const { data: subscription } = await testSupabase
      .from('subscriptions')
      .insert({
        user_id: testUserId,
        plan_id: 'starter',
        status: 'active'
      })
      .select()
      .single()

    // User should be able to read their own subscription
    const { data: userSubscription, error } = await userClient
      .from('subscriptions')
      .select('*')
      .eq('user_id', testUserId)
      .single()

    expect(error).toBeNull()
    expect(userSubscription).toBeDefined()
    expect(userSubscription.id).toBe(subscription.id)
  })

  it('should prevent users from reading other users subscriptions', async () => {
    // Create another user's subscription
    const { data: otherUser } = await testSupabase.auth.admin.createUser({
      email: 'other-rls-test@example.com',
      password: 'TestPassword123!',
      email_confirm: true
    })

    await testSupabase
      .from('subscriptions')
      .insert({
        user_id: otherUser.user!.id,
        plan_id: 'pro',
        status: 'active'
      })

    // User should NOT be able to read other user's subscription
    const { data: otherSubscription, error } = await userClient
      .from('subscriptions')
      .select('*')
      .eq('user_id', otherUser.user!.id)
      .single()

    expect(data).toBeNull()
    expect(error).toBeDefined()
    expect(error.code).toBe('PGRST116') // No rows returned due to RLS
  })

  it('should allow users to update their own subscription metadata', async () => {
    const { data: subscription } = await testSupabase
      .from('subscriptions')
      .insert({
        user_id: testUserId,
        plan_id: 'starter',
        status: 'active'
      })
      .select()
      .single()

    // User should be able to update their own subscription
    const { data: updated, error } = await userClient
      .from('subscriptions')
      .update({
        metadata: { user_updated: true }
      })
      .eq('id', subscription.id)
      .select()
      .single()

    expect(error).toBeNull()
    expect(updated.metadata).toEqual({ user_updated: true })
  })
})
```

## Stripe API Integration Tests

### Real Stripe Operations

```typescript
// __tests__/integration/stripe-operations.test.ts
import { testStripe, testSupabase } from './setup'
import { getStripePriceId } from '@/lib/plan-config'

describe('Stripe API Integration', () => {
  let testCustomer: any
  let testSubscription: any

  beforeAll(async () => {
    // Create real test customer
    testCustomer = await testStripe.customers.create({
      email: 'stripe-integration@test.com',
      name: 'Integration Test User',
      metadata: {
        test_source: 'integration_test'
      }
    })

    // Create real test subscription
    testSubscription = await testStripe.subscriptions.create({
      customer: testCustomer.id,
      items: [{ price: getStripePriceId('starter', 'month') }],
      metadata: {
        test_source: 'integration_test'
      }
    })
  })

  afterAll(async () => {
    // Clean up Stripe test data
    if (testSubscription) {
      await testStripe.subscriptions.cancel(testSubscription.id)
    }
    if (testCustomer) {
      await testStripe.customers.del(testCustomer.id)
    }
  })

  it('should upgrade subscription with real proration', async () => {
    const newPriceId = getStripePriceId('pro', 'month')
    const subscriptionItemId = testSubscription.items.data[0].id

    // Perform real upgrade
    const upgradedSubscription = await testStripe.subscriptions.update(testSubscription.id, {
      items: [{
        id: subscriptionItemId,
        price: newPriceId,
      }],
      proration_behavior: 'create_prorations',
    })

    expect(upgradedSubscription.status).toBe('active')
    expect(upgradedSubscription.items.data[0].price.id).toBe(newPriceId)

    // Verify proration invoice was created
    const invoices = await testStripe.invoices.list({
      customer: testCustomer.id,
      limit: 1
    })

    expect(invoices.data.length).toBeGreaterThan(0)
    
    const latestInvoice = invoices.data[0]
    const prorationItems = latestInvoice.lines.data.filter(line => line.proration)
    expect(prorationItems.length).toBeGreaterThan(0)
  })

  it('should create subscription schedule for interval changes', async () => {
    // Create schedule from subscription
    const schedule = await testStripe.subscriptionSchedules.create({
      from_subscription: testSubscription.id,
    })

    expect(schedule.subscription).toBe(testSubscription.id)
    expect(schedule.status).toBe('active')

    // Update with phases
    const monthlyPriceId = getStripePriceId('starter', 'month')
    const annualPriceId = getStripePriceId('starter', 'year')

    const updatedSchedule = await testStripe.subscriptionSchedules.update(schedule.id, {
      phases: [
        {
          items: [{ price: monthlyPriceId, quantity: 1 }],
          start_date: testSubscription.current_period_start,
          end_date: testSubscription.current_period_end,
        },
        {
          items: [{ price: annualPriceId, quantity: 1 }],
          start_date: testSubscription.current_period_end,
        }
      ]
    })

    expect(updatedSchedule.phases).toHaveLength(2)
    expect(updatedSchedule.phases[1].items[0].price).toBe(annualPriceId)

    // Clean up
    await testStripe.subscriptionSchedules.cancel(schedule.id)
  })

  it('should handle webhook signature verification', async () => {
    const event = {
      id: 'evt_integration_test',
      type: 'customer.subscription.updated',
      data: {
        object: testSubscription
      }
    }

    const payload = JSON.stringify(event)
    const signature = testStripe.webhooks.generateTestHeaderString({
      payload,
      secret: process.env.STRIPE_WEBHOOK_SECRET!
    })

    // Verify signature works
    const verifiedEvent = testStripe.webhooks.constructEvent(
      payload,
      signature,
      process.env.STRIPE_WEBHOOK_SECRET!
    )

    expect(verifiedEvent.id).toBe(event.id)
    expect(verifiedEvent.type).toBe(event.type)
  })
})
```

## Database Integration Tests

### Subscription Management Tests

```typescript
// __tests__/integration/subscription-management.test.ts
import { testSupabase } from './setup'

describe('Subscription Management Integration', () => {
  let testUserId: string

  beforeAll(async () => {
    // Create test user
    const { data: authUser } = await testSupabase.auth.admin.createUser({
      email: 'sub-mgmt-test@example.com',
      password: 'TestPassword123!',
      email_confirm: true
    })

    testUserId = authUser.user!.id

    await testSupabase
      .from('users')
      .insert({
        id: testUserId,
        email: 'sub-mgmt-test@example.com',
        first_name: 'Test',
        last_name: 'User'
      })
  })

  afterAll(async () => {
    await testSupabase.auth.admin.deleteUser(testUserId)
  })

  it('should create and retrieve subscription with RPC function', async () => {
    // Create subscription
    const { data: subscription, error: createError } = await testSupabase
      .from('subscriptions')
      .insert({
        user_id: testUserId,
        stripe_subscription_id: 'sub_integration_test',
        stripe_customer_id: 'cus_integration_test',
        plan_id: 'starter',
        status: 'active',
        current_period_start: new Date().toISOString(),
        current_period_end: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString()
      })
      .select()
      .single()

    expect(createError).toBeNull()
    expect(subscription).toBeDefined()

    // Retrieve with RPC function
    const { data: rpcResult, error: rpcError } = await testSupabase
      .rpc('get_user_active_subscription', { user_uuid: testUserId })

    expect(rpcError).toBeNull()
    expect(rpcResult).toBeDefined()
    expect(rpcResult.length).toBe(1)
    expect(rpcResult[0].id).toBe(subscription.id)
  })

  it('should enforce subscription status constraints', async () => {
    // Try to create subscription with invalid status
    const { data, error } = await testSupabase
      .from('subscriptions')
      .insert({
        user_id: testUserId,
        plan_id: 'starter',
        status: 'invalid_status' // Should fail constraint
      })

    expect(error).toBeDefined()
    expect(error.code).toBe('23514') // Check constraint violation
  })

  it('should cascade delete subscriptions when user is deleted', async () => {
    // Create user and subscription
    const { data: tempUser } = await testSupabase.auth.admin.createUser({
      email: 'cascade-test@example.com',
      password: 'TestPassword123!',
      email_confirm: true
    })

    const tempUserId = tempUser.user!.id

    await testSupabase
      .from('users')
      .insert({
        id: tempUserId,
        email: 'cascade-test@example.com',
        first_name: 'Temp',
        last_name: 'User'
      })

    const { data: subscription } = await testSupabase
      .from('subscriptions')
      .insert({
        user_id: tempUserId,
        plan_id: 'starter',
        status: 'active'
      })
      .select()
      .single()

    // Delete user (should cascade to subscription)
    await testSupabase.auth.admin.deleteUser(tempUserId)

    // Verify subscription was deleted
    const { data: deletedSub, error } = await testSupabase
      .from('subscriptions')
      .select('*')
      .eq('id', subscription.id)
      .single()

    expect(deletedSub).toBeNull()
    expect(error.code).toBe('PGRST116') // No rows returned
  })
})
```

## Webhook Integration Tests

### Real Webhook Processing

```typescript
// __tests__/integration/webhook-processing.test.ts
import { testSupabase, testStripe } from './setup'
import { handleInvoicePaymentPaid, handleSubscriptionScheduleUpdated } from '@/app/api/webhooks/stripe/handlers'

describe('Webhook Processing Integration', () => {
  let testCustomer: any
  let testSubscription: any
  let testUserId: string

  beforeAll(async () => {
    // Create test user
    const { data: authUser } = await testSupabase.auth.admin.createUser({
      email: 'webhook-test@example.com',
      password: 'TestPassword123!',
      email_confirm: true
    })

    testUserId = authUser.user!.id

    await testSupabase
      .from('users')
      .insert({
        id: testUserId,
        email: 'webhook-test@example.com',
        first_name: 'Webhook',
        last_name: 'Test'
      })

    // Create Stripe customer and subscription
    testCustomer = await testStripe.customers.create({
      email: 'webhook-test@example.com',
      metadata: { userId: testUserId }
    })

    testSubscription = await testStripe.subscriptions.create({
      customer: testCustomer.id,
      items: [{ price: getStripePriceId('starter', 'month') }]
    })

    // Create in database
    await testSupabase
      .from('subscriptions')
      .insert({
        user_id: testUserId,
        stripe_subscription_id: testSubscription.id,
        stripe_customer_id: testCustomer.id,
        plan_id: 'starter',
        status: 'active'
      })
  })

  afterAll(async () => {
    // Cleanup
    await testStripe.subscriptions.cancel(testSubscription.id)
    await testStripe.customers.del(testCustomer.id)
    await testSupabase.auth.admin.deleteUser(testUserId)
  })

  it('should process invoice.payment_succeeded webhook', async () => {
    // Create real invoice
    const invoice = await testStripe.invoices.create({
      customer: testCustomer.id,
      subscription: testSubscription.id
    })

    await testStripe.invoices.finalizeInvoice(invoice.id)
    await testStripe.invoices.pay(invoice.id)

    const paidInvoice = await testStripe.invoices.retrieve(invoice.id)

    // Process webhook
    const result = await handleInvoicePaymentPaid(paidInvoice)

    expect(result).toBeDefined()
    expect(result.id).toBeDefined()

    // Verify database was updated
    const { data: updatedSub } = await testSupabase
      .from('subscriptions')
      .select('*')
      .eq('stripe_subscription_id', testSubscription.id)
      .single()

    expect(updatedSub.status).toBe('active')
    expect(updatedSub.current_period_start).toBeDefined()
    expect(updatedSub.current_period_end).toBeDefined()
  })

  it('should process subscription schedule updates', async () => {
    // Create real subscription schedule
    const schedule = await testStripe.subscriptionSchedules.create({
      from_subscription: testSubscription.id,
    })

    // Add metadata to indicate schedule entering phase 2
    const mockScheduleUpdate = {
      id: schedule.id,
      subscription: testSubscription.id,
      status: 'active',
      current_phase: {
        start_date: Math.floor(Date.now() / 1000) + 86400 // Tomorrow
      },
      phases: [
        {
          start_date: Math.floor(Date.now() / 1000),
          end_date: Math.floor(Date.now() / 1000) + 86400
        },
        {
          start_date: Math.floor(Date.now() / 1000) + 86400
        }
      ]
    }

    // Add scheduled change metadata to subscription
    await testSupabase
      .from('subscriptions')
      .update({
        metadata: {
          scheduled_change: {
            planId: 'pro',
            interval: 'month',
            effectiveAt: new Date(Date.now() + 86400 * 1000).toISOString()
          }
        }
      })
      .eq('stripe_subscription_id', testSubscription.id)

    // Process webhook
    await handleSubscriptionScheduleUpdated(mockScheduleUpdate)

    // Verify scheduled_change metadata was cleared
    const { data: updatedSub } = await testSupabase
      .from('subscriptions')
      .select('metadata')
      .eq('stripe_subscription_id', testSubscription.id)
      .single()

    expect(updatedSub.metadata.scheduled_change).toBeUndefined()

    // Cleanup
    await testStripe.subscriptionSchedules.cancel(schedule.id)
  })
})
```

## Performance Integration Tests

### Database Performance Tests

```typescript
// __tests__/integration/performance.test.ts
import { testSupabase } from './setup'

describe('Database Performance Integration', () => {
  beforeAll(async () => {
    // Create large dataset for performance testing
    await seedLargeDataset()
  })

  it('should perform subscription queries efficiently', async () => {
    const startTime = Date.now()

    // Test subscription lookup performance
    const { data, error } = await testSupabase
      .rpc('get_user_active_subscription', { 
        user_uuid: 'performance_test_user' 
      })

    const queryTime = Date.now() - startTime

    expect(error).toBeNull()
    expect(queryTime).toBeLessThan(100) // Should complete in under 100ms
  })

  it('should aggregate usage efficiently for large datasets', async () => {
    const startTime = Date.now()

    const { data, error } = await testSupabase
      .rpc('get_usage_summary', {
        user_uuid: 'performance_test_user',
        period_start: new Date('2024-01-01').toISOString(),
        period_end: new Date('2024-02-01').toISOString()
      })

    const queryTime = Date.now() - startTime

    expect(error).toBeNull()
    expect(queryTime).toBeLessThan(500) // Should complete in under 500ms
  })

  async function seedLargeDataset() {
    // Create test user
    const { data: authUser } = await testSupabase.auth.admin.createUser({
      email: 'performance-test@example.com',
      password: 'TestPassword123!',
      email_confirm: true
    })

    await testSupabase
      .from('users')
      .insert({
        id: authUser.user!.id,
        email: 'performance-test@example.com',
        first_name: 'Performance',
        last_name: 'Test'
      })

    // Create large number of usage records
    const usageRecords = []
    for (let i = 0; i < 10000; i++) {
      usageRecords.push({
        user_id: authUser.user!.id,
        feature_name: 'compute_minutes',
        usage_amount: Math.floor(Math.random() * 100),
        created_at: new Date(Date.now() - Math.random() * 30 * 24 * 60 * 60 * 1000).toISOString()
      })
    }

    // Insert in batches
    const batchSize = 1000
    for (let i = 0; i < usageRecords.length; i += batchSize) {
      const batch = usageRecords.slice(i, i + batchSize)
      await testSupabase.from('usage_records').insert(batch)
    }
  }
})
```

## Test Utilities

### Integration Test Helpers

```typescript
// __tests__/integration/test-helpers.ts
export async function createTestSubscriptionFlow(
  planId: string,
  billingInterval: 'month' | 'year' = 'month'
): Promise<{
  user: any
  customer: any
  subscription: any
  dbSubscription: any
}> {
  
  // Create user
  const { data: authUser } = await testSupabase.auth.admin.createUser({
    email: `integration-${Date.now()}@test.com`,
    password: 'TestPassword123!',
    email_confirm: true
  })

  const userId = authUser.user!.id

  await testSupabase
    .from('users')
    .insert({
      id: userId,
      email: authUser.user!.email,
      first_name: 'Integration',
      last_name: 'Test'
    })

  // Create Stripe customer
  const customer = await testStripe.customers.create({
    email: authUser.user!.email,
    metadata: { userId: userId }
  })

  // Create Stripe subscription
  const priceId = getStripePriceId(planId, billingInterval)
  const subscription = await testStripe.subscriptions.create({
    customer: customer.id,
    items: [{ price: priceId }],
    metadata: {
      userId: userId,
      planId: planId
    }
  })

  // Create database subscription
  const { data: dbSubscription } = await testSupabase
    .from('subscriptions')
    .insert({
      user_id: userId,
      stripe_subscription_id: subscription.id,
      stripe_customer_id: customer.id,
      stripe_price_id: priceId,
      plan_id: planId,
      status: 'active',
      current_period_start: new Date(subscription.current_period_start * 1000).toISOString(),
      current_period_end: new Date(subscription.current_period_end * 1000).toISOString()
    })
    .select()
    .single()

  return {
    user: authUser.user!,
    customer,
    subscription,
    dbSubscription
  }
}

export async function cleanupTestSubscriptionFlow(testData: any) {
  try {
    // Cancel Stripe subscription
    await testStripe.subscriptions.cancel(testData.subscription.id)
    
    // Delete Stripe customer
    await testStripe.customers.del(testData.customer.id)
    
    // Delete user (cascades to subscription)
    await testSupabase.auth.admin.deleteUser(testData.user.id)
    
  } catch (error) {
    console.error('Cleanup failed:', error)
  }
}
```

## Next Steps

In the next module, we'll continue with the E2E testing module we already created, and then move on to test data management strategies.

## Key Takeaways

- Use real Stripe test data for integration tests
- Test with real database to verify RLS policies and constraints
- Create comprehensive test scenarios covering the full billing flow
- Test webhook processing with real Stripe event data
- Verify proration calculations with actual Stripe operations
- Test subscription schedules with real phase transitions
- Implement proper test setup and cleanup procedures
- Test database performance with realistic data volumes
- Use integration tests to verify API contract compliance
- Test error scenarios and edge cases with real services
