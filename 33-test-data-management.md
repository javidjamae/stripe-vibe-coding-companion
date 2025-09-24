# Test Data Management for Stripe Integration

## Overview

This module covers managing test customers, subscriptions, and billing data for reliable testing. Based on your codebase patterns, we'll explore the seed helper system, test data lifecycle, and cleanup strategies that ensure consistent test environments.

## Your Test Data Architecture

Your codebase implements a sophisticated test data management system:

```
Cypress Tasks → Seed Helpers → Stripe Test Mode → Database → Cleanup
```

### Core Components

1. **Seed Helpers**: Create deterministic test data
2. **Test Mode Detection**: Handle test vs production environments
3. **Cleanup Tasks**: Remove test data after test runs
4. **Unique Identifiers**: Prevent test interference

## Seed Helper Patterns (Your Actual Implementation)

### Core Seed Function

From your actual Cypress seed helpers:

```typescript
// Your actual seedStarterUserWithStripeSubscription implementation
export async function seedStarterUserWithStripeSubscription(email: string) {
  console.log(`🌱 Seeding Starter user with Stripe subscription: ${email}`)
  
  try {
    // Create user in Supabase Auth
    const { data: authUser, error: authError } = await supabaseAdmin.auth.admin.createUser({
      email: email,
      password: 'TestPassword123!',
      email_confirm: true
    })

    if (authError) {
      throw new Error(`Auth user creation failed: ${authError.message}`)
    }

    const userId = authUser.user.id

    // Create user profile
    const { error: profileError } = await supabaseAdmin
      .from('users')
      .insert({
        id: userId,
        email: email,
        first_name: 'Test',
        last_name: 'User',
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      })

    if (profileError) {
      throw new Error(`Profile creation failed: ${profileError.message}`)
    }

    // Create Stripe customer
    const customer = await stripe.customers.create({
      email: email,
      name: 'Test User',
      metadata: {
        userId: userId,
        test_source: 'cypress'
      }
    })

    // Create Stripe subscription
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
    })

    // Create subscription in database
    const { error: subError } = await supabaseAdmin
      .from('subscriptions')
      .insert({
        user_id: userId,
        stripe_subscription_id: subscription.id,
        stripe_customer_id: customer.id,
        stripe_price_id: 'price_1S1EmGHxCxqKRRWFzsKZxGSY',
        plan_id: 'starter',
        status: 'active',
        current_period_start: new Date(subscription.current_period_start * 1000).toISOString(),
        current_period_end: new Date(subscription.current_period_end * 1000).toISOString(),
        cancel_at_period_end: false,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString()
      })

    if (subError) {
      throw new Error(`Subscription creation failed: ${subError.message}`)
    }

    console.log(`✅ Successfully seeded Starter user: ${userId}`)
    return {
      ok: true,
      userId: userId,
      customerId: customer.id,
      subscriptionId: subscription.id
    }

  } catch (error) {
    console.error('❌ Seed operation failed:', error)
    return {
      ok: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    }
  }
}
```

**Key Patterns from Your Implementation**:
- Creates complete user lifecycle: Auth → Profile → Stripe Customer → Subscription → Database
- Uses consistent metadata tagging with `test_source: 'cypress'`
- Returns structured result with IDs for further test operations
- Handles errors gracefully with detailed error messages

## Test Data Variations (Your Actual Patterns)

### Different Plan Types

```typescript
// Your pattern for different plan subscriptions
export async function seedProUserWithStripeSubscription(email: string) {
  // Same pattern as seedStarterUser but with Pro plan price
  const subscription = await stripe.subscriptions.create({
    customer: customer.id,
    items: [{
      price: 'price_1S1EmZHxCxqKRRWF8fQgO6d2' // Pro monthly price
    }],
    metadata: {
      userId: userId,
      planId: 'pro',
      test_source: 'cypress'
    }
  })
  
  // Database insertion with pro plan
  await supabaseAdmin
    .from('subscriptions')
    .insert({
      // ... other fields
      plan_id: 'pro',
      stripe_price_id: 'price_1S1EmZHxCxqKRRWF8fQgO6d2'
    })
}

export async function seedAnnualUserWithStripeSubscription(email: string, planId: string = 'pro') {
  // Same pattern but with annual pricing
  const annualPriceId = getStripePriceId(planId, 'year')
  
  const subscription = await stripe.subscriptions.create({
    customer: customer.id,
    items: [{ price: annualPriceId }],
    metadata: {
      userId: userId,
      planId: planId,
      billingInterval: 'year',
      test_source: 'cypress'
    }
  })
}
```

### Scheduled Change Scenarios

```typescript
// Your pattern for users with scheduled changes
export async function seedUserWithScheduledDowngrade(email: string) {
  // First create a normal subscription
  const result = await seedStarterUserWithStripeSubscription(email)
  
  if (!result.ok) {
    return result
  }

  try {
    // Update Stripe subscription to have cancel_at_period_end = true
    await stripe.subscriptions.update(result.subscriptionId, {
      cancel_at_period_end: true
    })

    // Update database with scheduled change metadata
    const scheduledChange = {
      planId: 'free',
      interval: 'month',
      priceId: 'price_1S1EldHxCxqKRRWFkYhT6myo',
      effectiveAt: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString()
    }

    await supabaseAdmin
      .from('subscriptions')
      .update({
        cancel_at_period_end: true,
        metadata: {
          scheduled_change: scheduledChange
        }
      })
      .eq('stripe_subscription_id', result.subscriptionId)

    console.log(`✅ Added scheduled downgrade for user: ${result.userId}`)
    return result

  } catch (error) {
    console.error('❌ Failed to add scheduled downgrade:', error)
    return {
      ok: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    }
  }
}
```

## Test Data Lifecycle Management

### Unique Email Generation

```typescript
// Your pattern for unique test emails
describe('Upgrade Flow', () => {
  const email = `upgrade-test-${Date.now()}@example.com`
  
  beforeEach(() => {
    cy.task('seedStarterUserWithStripeSubscription', { email })
  })
})

// Alternative pattern with more specificity
describe('Billing Tests', () => {
  const baseEmail = 'billing-test'
  
  it('should handle starter upgrade', () => {
    const email = `${baseEmail}-starter-${Date.now()}@example.com`
    cy.task('seedStarterUserWithStripeSubscription', { email })
  })
  
  it('should handle pro downgrade', () => {
    const email = `${baseEmail}-pro-${Date.now()}@example.com`
    cy.task('seedProUserWithStripeSubscription', { email })
  })
})
```

### Test Mode Detection

```typescript
// Your pattern for test mode handling in APIs
export async function POST(request: Request) {
  // Check if this is a Cypress test request
  const isTestMode = request.headers.get('x-test-mode') === 'cypress'
  
  if (isTestMode) {
    // Mock Stripe call for tests - return fake success
    const testEndDate = new Date()
    testEndDate.setDate(testEndDate.getDate() + 20) // 20 days from now
    
    updatedSubscription = {
      id: subscription.stripe_subscription_id,
      status: 'active',
      current_period_start: Math.floor(Date.now() / 1000),
      current_period_end: Math.floor(testEndDate.getTime() / 1000)
    }
  } else {
    // Real Stripe call for production
    updatedSubscription = await stripe.subscriptions.update(/* ... */)
  }
}
```

**Key Benefits of This Pattern**:
- Tests run faster (no real Stripe API calls)
- Tests are more reliable (no network dependencies)
- Tests can simulate specific scenarios easily
- Production code path still gets tested in integration tests

## Test Data Cleanup (Your Actual Implementation)

### Cypress Task for Cleanup

```typescript
// cypress/tasks/cleanup.ts
export async function cleanupTestData() {
  console.log('🧹 Cleaning up test data...')
  
  try {
    // Delete test users from Stripe (identified by metadata)
    const customers = await stripe.customers.list({
      limit: 100,
      expand: ['data.subscriptions']
    })
    
    for (const customer of customers.data) {
      if (customer.metadata?.test_source === 'cypress') {
        // Cancel subscriptions first
        if (customer.subscriptions?.data.length) {
          for (const subscription of customer.subscriptions.data) {
            await stripe.subscriptions.cancel(subscription.id)
          }
        }
        
        // Delete customer
        await stripe.customers.del(customer.id)
        console.log(`✅ Deleted test customer: ${customer.id}`)
      }
    }

    // Delete test users from database
    const { error } = await supabaseAdmin
      .from('users')
      .delete()
      .like('email', '%cypress%')

    if (error) {
      console.error('Database cleanup error:', error)
    } else {
      console.log('✅ Database cleanup completed')
    }

    return { ok: true }

  } catch (error) {
    console.error('❌ Cleanup failed:', error)
    return { 
      ok: false, 
      error: error instanceof Error ? error.message : 'Unknown error' 
    }
  }
}
```

### Cleanup Strategy

**Your Cleanup Approach**:
1. **Metadata Tagging**: All test data tagged with `test_source: 'cypress'`
2. **Stripe First**: Cancel subscriptions before deleting customers
3. **Database Cascade**: User deletion cascades to related tables
4. **Email Pattern**: Delete users with emails containing 'cypress'

## Test Data Isolation Patterns

### Per-Test Isolation

```typescript
// Your pattern for test isolation
describe('Billing Flow', () => {
  beforeEach(() => {
    // Clear any existing session
    cy.clearCookies()
    cy.clearLocalStorage()
    
    // Each test gets fresh data
    const email = `test-${Date.now()}@example.com`
    cy.task('seedStarterUserWithStripeSubscription', { email })
  })
})
```

### Shared Test Data

```typescript
// Pattern for tests that can share data
describe('Read-Only Billing Tests', () => {
  const sharedEmail = `shared-${Date.now()}@example.com`
  
  before(() => {
    // Create once for all tests in this suite
    cy.task('seedStarterUserWithStripeSubscription', { email: sharedEmail })
  })
  
  after(() => {
    // Cleanup shared data
    cy.task('cleanupTestUser', { email: sharedEmail })
  })
})
```

## Database State Verification

### Your Database Query Helpers

```typescript
// cypress/tasks/database-helpers.ts
export async function getSubscriptionForEmail(email: string) {
  try {
    const { data: user } = await supabaseAdmin
      .from('users')
      .select('id')
      .eq('email', email)
      .single()

    if (!user) {
      return { ok: false, error: 'User not found' }
    }

    const { data: subscription, error } = await supabaseAdmin
      .from('subscriptions')
      .select('*')
      .eq('user_id', user.id)
      .single()

    if (error) {
      return { ok: false, error: error.message }
    }

    return {
      ok: true,
      subscription: subscription
    }

  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    }
  }
}

export async function getStripeCancelFlagForEmail(email: string) {
  try {
    const user = await getUserByEmail(email)
    
    const { data: subscription, error } = await supabaseAdmin
      .from('subscriptions')
      .select('stripe_subscription_id')
      .eq('user_id', user.id)
      .single()

    if (error || !subscription?.stripe_subscription_id) {
      return { ok: false, error: 'Subscription not found' }
    }

    // Get from Stripe
    const stripeSubscription = await stripe.subscriptions.retrieve(
      subscription.stripe_subscription_id
    )

    return {
      ok: true,
      cancel_at_period_end: stripeSubscription.cancel_at_period_end
    }

  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    }
  }
}
```

## Test Data Factories

### Plan-Specific Factories

```typescript
// Test data factories based on your patterns
export const TestDataFactory = {
  // Free user (database only, no Stripe)
  async createFreeUser(email: string) {
    const { data: authUser, error: authError } = await supabaseAdmin.auth.admin.createUser({
      email: email,
      password: 'TestPassword123!',
      email_confirm: true
    })

    if (authError) throw new Error(`Auth user creation failed: ${authError.message}`)

    const userId = authUser.user.id

    // Create user profile
    await supabaseAdmin.from('users').insert({
      id: userId,
      email: email,
      first_name: 'Test',
      last_name: 'User'
    })

    // Create free subscription (no Stripe linkage)
    await supabaseAdmin.from('subscriptions').insert({
      user_id: userId,
      plan_id: 'free',
      status: 'active'
    })

    return { userId, email }
  },

  // Paid user with Stripe subscription
  async createPaidUser(email: string, planId: string = 'starter', interval: 'month' | 'year' = 'month') {
    const priceId = getStripePriceId(planId, interval)
    if (!priceId) throw new Error(`No price ID for ${planId} ${interval}`)

    // Create auth user and profile (same as free user)
    const { userId } = await this.createFreeUser(email)

    // Create Stripe customer and subscription
    const customer = await stripe.customers.create({
      email: email,
      name: 'Test User',
      metadata: { userId, test_source: 'cypress' }
    })

    const subscription = await stripe.subscriptions.create({
      customer: customer.id,
      items: [{ price: priceId }],
      metadata: { userId, planId, test_source: 'cypress' }
    })

    // Update database subscription with Stripe data
    await supabaseAdmin
      .from('subscriptions')
      .update({
        stripe_subscription_id: subscription.id,
        stripe_customer_id: customer.id,
        stripe_price_id: priceId,
        plan_id: planId,
        current_period_start: new Date(subscription.current_period_start * 1000).toISOString(),
        current_period_end: new Date(subscription.current_period_end * 1000).toISOString()
      })
      .eq('user_id', userId)

    return { userId, customerId: customer.id, subscriptionId: subscription.id }
  },

  // User with scheduled change
  async createUserWithScheduledChange(email: string, fromPlan: string, toPlan: string) {
    const { userId, subscriptionId } = await this.createPaidUser(email, fromPlan)

    // Add scheduled change metadata
    const scheduledChange = {
      planId: toPlan,
      interval: 'month',
      priceId: getStripePriceId(toPlan, 'month'),
      effectiveAt: new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString()
    }

    await supabaseAdmin
      .from('subscriptions')
      .update({
        cancel_at_period_end: true,
        metadata: { scheduled_change: scheduledChange }
      })
      .eq('user_id', userId)

    return { userId, subscriptionId }
  }
}
```

## Environment-Specific Configuration

### Test Environment Setup

```typescript
// cypress/support/test-config.ts
export const TestConfig = {
  // Use different price IDs for different environments if needed
  getPriceId: (planId: string, interval: 'month' | 'year') => {
    if (Cypress.env('TEST_ENVIRONMENT') === 'staging') {
      return getStagingPriceId(planId, interval)
    }
    return getStripePriceId(planId, interval)
  },

  // Test-specific timeouts
  getTimeout: (operation: 'seed' | 'api' | 'ui') => {
    switch (operation) {
      case 'seed': return 30000  // 30s for seed operations
      case 'api': return 15000   // 15s for API calls
      case 'ui': return 10000    // 10s for UI interactions
      default: return 5000
    }
  },

  // Test data cleanup settings
  shouldCleanup: () => {
    return Cypress.env('CLEANUP_TEST_DATA') !== 'false'
  }
}
```

## Test Data Verification

### Data Consistency Checks

```typescript
// cypress/tasks/verification.ts
export async function verifyTestDataConsistency(email: string) {
  console.log(`🔍 Verifying test data consistency for ${email}`)
  
  try {
    // Get user from database
    const { data: user } = await supabaseAdmin
      .from('users')
      .select('id')
      .eq('email', email)
      .single()

    if (!user) {
      return { ok: false, error: 'User not found in database' }
    }

    // Get subscription from database
    const { data: dbSubscription } = await supabaseAdmin
      .from('subscriptions')
      .select('*')
      .eq('user_id', user.id)
      .single()

    if (!dbSubscription) {
      return { ok: false, error: 'Subscription not found in database' }
    }

    // If subscription has Stripe ID, verify it exists in Stripe
    if (dbSubscription.stripe_subscription_id) {
      try {
        const stripeSubscription = await stripe.subscriptions.retrieve(
          dbSubscription.stripe_subscription_id
        )

        // Verify key fields match
        const inconsistencies = []
        
        if (stripeSubscription.status !== dbSubscription.status) {
          inconsistencies.push(`Status mismatch: Stripe=${stripeSubscription.status}, DB=${dbSubscription.status}`)
        }

        if (stripeSubscription.items.data[0]?.price?.id !== dbSubscription.stripe_price_id) {
          inconsistencies.push(`Price ID mismatch: Stripe=${stripeSubscription.items.data[0]?.price?.id}, DB=${dbSubscription.stripe_price_id}`)
        }

        if (inconsistencies.length > 0) {
          return { ok: false, error: `Data inconsistencies: ${inconsistencies.join(', ')}` }
        }

      } catch (stripeError) {
        return { ok: false, error: `Stripe subscription not found: ${dbSubscription.stripe_subscription_id}` }
      }
    }

    console.log('✅ Test data consistency verified')
    return { ok: true }

  } catch (error) {
    return {
      ok: false,
      error: error instanceof Error ? error.message : 'Unknown error'
    }
  }
}
```

## Performance Optimization for Test Data

### Parallel Seed Operations

```typescript
// Optimize test data creation for speed
export async function seedMultipleUsers(users: { email: string, plan: string }[]) {
  console.log(`🌱 Seeding ${users.length} users in parallel`)
  
  try {
    // Create auth users in parallel
    const authPromises = users.map(user => 
      supabaseAdmin.auth.admin.createUser({
        email: user.email,
        password: 'TestPassword123!',
        email_confirm: true
      })
    )
    
    const authResults = await Promise.all(authPromises)
    
    // Create profiles in parallel
    const profileData = authResults.map((result, index) => ({
      id: result.data.user.id,
      email: users[index].email,
      first_name: 'Test',
      last_name: 'User'
    }))
    
    await supabaseAdmin.from('users').insert(profileData)
    
    // Create Stripe customers in parallel
    const customerPromises = profileData.map(profile =>
      stripe.customers.create({
        email: profile.email,
        name: 'Test User',
        metadata: {
          userId: profile.id,
          test_source: 'cypress'
        }
      })
    )
    
    const customers = await Promise.all(customerPromises)
    
    // Create subscriptions in parallel
    const subscriptionPromises = customers.map((customer, index) => {
      const priceId = getStripePriceId(users[index].plan, 'month')
      return stripe.subscriptions.create({
        customer: customer.id,
        items: [{ price: priceId }],
        metadata: {
          userId: profileData[index].id,
          planId: users[index].plan,
          test_source: 'cypress'
        }
      })
    })
    
    const subscriptions = await Promise.all(subscriptionPromises)
    
    // Update database subscriptions in parallel
    const dbUpdates = subscriptions.map((subscription, index) =>
      supabaseAdmin
        .from('subscriptions')
        .update({
          stripe_subscription_id: subscription.id,
          stripe_customer_id: customers[index].id,
          stripe_price_id: getStripePriceId(users[index].plan, 'month'),
          plan_id: users[index].plan,
          current_period_start: new Date(subscription.current_period_start * 1000).toISOString(),
          current_period_end: new Date(subscription.current_period_end * 1000).toISOString()
        })
        .eq('user_id', profileData[index].id)
    )
    
    await Promise.all(dbUpdates)
    
    console.log(`✅ Successfully seeded ${users.length} users`)
    return { ok: true, users: profileData }

  } catch (error) {
    console.error('❌ Parallel seed operation failed:', error)
    return { ok: false, error: error instanceof Error ? error.message : 'Unknown error' }
  }
}
```

## Test Data Debugging

### Debug Helpers

```typescript
// cypress/tasks/debug-helpers.ts
export async function debugTestUser(email: string) {
  console.log(`🐛 Debugging test user: ${email}`)
  
  try {
    // Check auth user
    const { data: authUsers } = await supabaseAdmin.auth.admin.listUsers()
    const authUser = authUsers.users.find(u => u.email === email)
    console.log('Auth user:', authUser ? 'Found' : 'Not found')
    
    if (authUser) {
      // Check profile
      const { data: profile } = await supabaseAdmin
        .from('users')
        .select('*')
        .eq('id', authUser.id)
        .single()
      console.log('Profile:', profile ? 'Found' : 'Not found')
      
      if (profile) {
        // Check subscription
        const { data: subscription } = await supabaseAdmin
          .from('subscriptions')
          .select('*')
          .eq('user_id', profile.id)
          .single()
        console.log('Subscription:', subscription ? 'Found' : 'Not found')
        
        if (subscription?.stripe_subscription_id) {
          // Check Stripe subscription
          try {
            const stripeSubscription = await stripe.subscriptions.retrieve(
              subscription.stripe_subscription_id
            )
            console.log('Stripe subscription:', stripeSubscription ? 'Found' : 'Not found')
            console.log('Stripe status:', stripeSubscription.status)
          } catch (stripeError) {
            console.log('Stripe subscription: Not found or error')
          }
        }
      }
    }
    
    return { ok: true }

  } catch (error) {
    console.log('Debug error:', error)
    return { ok: false, error: error instanceof Error ? error.message : 'Unknown error' }
  }
}
```

## Next Steps

In the next module, we'll cover testing webhook handlers and failure scenarios.

## Key Takeaways

- **Use seed helpers** to create consistent, deterministic test data
- **Tag all test data** with metadata for easy identification and cleanup
- **Create data factories** for different user scenarios and plan types
- **Implement cleanup tasks** to prevent test data pollution
- **Use unique emails** with timestamps to avoid test interference
- **Verify data consistency** between your database and Stripe
- **Optimize performance** with parallel operations where possible
- **Debug test data** with helper functions when tests fail
- **Handle test mode** differently from production in your APIs
- **Clean up systematically** starting with Stripe, then database
