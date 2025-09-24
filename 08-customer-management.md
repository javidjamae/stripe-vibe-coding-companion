# Customer Management and Data Synchronization

## Overview

This module covers customer management patterns in your Stripe integration, including customer creation, data synchronization between your system and Stripe, and handling customer lifecycle events.

## Customer Management Strategy

Your codebase implements a hybrid customer management approach that balances efficiency with data consistency:

### 1. Database-First Lookup

```typescript
// Always check your database first for existing customer relationship
const existingSubscription = await getSubscriptionDetails(userId)
if (existingSubscription?.stripeCustomerId) {
  // Use existing customer ID from database
  stripeCustomerId = existingSubscription.stripeCustomerId
}
```

**Benefits**:
- Faster lookups (single database query)
- Avoids unnecessary Stripe API calls
- Maintains relationship consistency

### 2. Stripe Fallback Search

```typescript
else {
  // Search Stripe for existing customer by email
  let customer = await stripe.customers.list({ email: userEmail, limit: 1 })
  
  if (customer.data.length > 0) {
    // Customer exists in Stripe but not linked in our database
    stripeCustomerId = customer.data[0].id
    
    // Update our database with the found customer ID
    await linkCustomerToUser(userId, stripeCustomerId)
  }
}
```

**Benefits**:
- Recovers from data synchronization issues
- Handles edge cases where customers exist in Stripe but not in database
- Prevents duplicate customer creation

### 3. New Customer Creation

```typescript
else {
  // Create new customer in Stripe
  const newCustomer = await stripe.customers.create({
    email: userEmail,
    name: `${user.firstName} ${user.lastName}`.trim(),
    metadata: {
      userId: userId,
      source: 'checkout_flow',
      created_at: new Date().toISOString()
    }
  })
  
  stripeCustomerId = newCustomer.id
  
  // Store customer ID in database
  await linkCustomerToUser(userId, stripeCustomerId)
}
```

## Customer Creation Patterns

### Complete Customer Creation Function

```typescript
// lib/customer-management.ts
export async function getOrCreateStripeCustomer(
  userId: string, 
  userEmail: string, 
  userProfile?: { firstName?: string; lastName?: string }
): Promise<string> {
  console.log(`🔍 Getting or creating Stripe customer for user ${userId}`)
  
  // 1. Check database first
  const existingSubscription = await getSubscriptionDetails(userId)
  if (existingSubscription?.stripeCustomerId) {
    console.log(`✅ Found existing customer: ${existingSubscription.stripeCustomerId}`)
    return existingSubscription.stripeCustomerId
  }

  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  // 2. Search Stripe by email
  const existingCustomers = await stripe.customers.list({ 
    email: userEmail, 
    limit: 1 
  })
  
  if (existingCustomers.data.length > 0) {
    const customerId = existingCustomers.data[0].id
    console.log(`✅ Found existing Stripe customer: ${customerId}`)
    
    // Link customer to user in database
    await linkCustomerToUser(userId, customerId)
    return customerId
  }

  // 3. Create new customer
  console.log(`🆕 Creating new Stripe customer for ${userEmail}`)
  
  const customerData: Stripe.CustomerCreateParams = {
    email: userEmail,
    metadata: {
      userId: userId,
      source: 'app_signup',
      created_at: new Date().toISOString()
    }
  }
  
  // Add name if available
  if (userProfile?.firstName || userProfile?.lastName) {
    customerData.name = `${userProfile.firstName || ''} ${userProfile.lastName || ''}`.trim()
  }

  const newCustomer = await stripe.customers.create(customerData)
  
  // Store customer relationship
  await linkCustomerToUser(userId, newCustomer.id)
  
  console.log(`✅ Created new customer: ${newCustomer.id}`)
  return newCustomer.id
}

async function linkCustomerToUser(userId: string, stripeCustomerId: string): Promise<void> {
  const supabase = createServerServiceRoleClient()
  
  // Update or create subscription record with customer ID
  const { error } = await supabase
    .from('subscriptions')
    .upsert({
      user_id: userId,
      stripe_customer_id: stripeCustomerId,
      plan_id: 'free', // Default to free plan
      status: 'active',
      updated_at: new Date().toISOString()
    })

  if (error) {
    console.error('❌ Error linking customer to user:', error)
    throw error
  }
}
```

## Customer Data Synchronization

### User Profile Updates

Sync user profile changes to Stripe:

```typescript
// lib/customer-sync.ts
export async function syncUserProfileToStripe(userId: string, updates: {
  email?: string
  firstName?: string
  lastName?: string
  phone?: string
}) {
  console.log(`🔄 Syncing user profile to Stripe for user ${userId}`)
  
  try {
    const subscription = await getSubscriptionDetails(userId)
    if (!subscription?.stripeCustomerId) {
      console.log('No Stripe customer to sync')
      return
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    const updateData: Stripe.CustomerUpdateParams = {}
    
    // Update email
    if (updates.email) {
      updateData.email = updates.email
    }
    
    // Update name
    if (updates.firstName !== undefined || updates.lastName !== undefined) {
      updateData.name = `${updates.firstName || ''} ${updates.lastName || ''}`.trim()
    }
    
    // Update phone
    if (updates.phone) {
      updateData.phone = updates.phone
    }
    
    // Update metadata with sync timestamp
    updateData.metadata = {
      last_profile_sync: new Date().toISOString(),
      synced_from: 'user_profile_update'
    }

    if (Object.keys(updateData).length === 1 && updateData.metadata) {
      // Only metadata update, skip API call
      return
    }

    await stripe.customers.update(subscription.stripeCustomerId, updateData)
    
    console.log(`✅ Profile synced to Stripe customer ${subscription.stripeCustomerId}`)
  } catch (error) {
    console.error('❌ Error syncing profile to Stripe:', error)
    // Don't throw - profile sync failures shouldn't break user updates
  }
}
```

### API Endpoint for Profile Updates

```typescript
// app/api/user/profile/route.ts
export async function PUT(request: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    const updates = await request.json()
    const { firstName, lastName, phone } = updates
    
    // Update user profile in database
    const { data, error } = await supabase
      .from('users')
      .update({
        first_name: firstName,
        last_name: lastName,
        phone: phone,
        updated_at: new Date().toISOString()
      })
      .eq('id', user.id)
      .select()
      .single()

    if (error) {
      console.error('Error updating user profile:', error)
      return new Response(
      JSON.stringify({ error: 'Failed to update profile' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
    }

    // Sync to Stripe asynchronously (don't await to avoid blocking response)
    syncUserProfileToStripe(user.id, {
      firstName,
      lastName,
      phone
    }).catch(error => {
      console.error('Background Stripe sync failed:', error)
    })

    return new Response(
      JSON.stringify({ data })
  } catch (error) {
    console.error('Profile update error:', error)
    return new Response(
      JSON.stringify({ error: 'Internal server error' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Customer Webhook Events

Handle customer-related webhook events:

### customer.updated

```typescript
// handlers.ts
export async function handleCustomerUpdated(customer: any) {
  console.log('👤 Processing customer.updated')
  console.log('Customer ID:', customer.id)
  console.log('Email:', customer.email)
  
  try {
    const supabase = createServerServiceRoleClient()
    
    // Find user by customer ID
    const { data: subscription, error } = await supabase
      .from('subscriptions')
      .select('user_id, users!inner(id, email)')
      .eq('stripe_customer_id', customer.id)
      .single()

    if (error || !subscription) {
      console.log(`❌ No user found for customer ${customer.id}`)
      return
    }

    // Update user profile with Stripe data
    const updates: any = {}
    
    if (customer.email && customer.email !== subscription.users.email) {
      updates.email = customer.email
    }
    
    if (customer.name) {
      const nameParts = customer.name.split(' ')
      updates.first_name = nameParts[0] || ''
      updates.last_name = nameParts.slice(1).join(' ') || ''
    }
    
    if (customer.phone) {
      updates.phone = customer.phone
    }

    if (Object.keys(updates).length > 0) {
      updates.updated_at = new Date().toISOString()
      
      const { error: updateError } = await supabase
        .from('users')
        .update(updates)
        .eq('id', subscription.user_id)

      if (updateError) {
        console.error('❌ Error updating user from customer webhook:', updateError)
        return
      }

      console.log(`✅ Updated user profile from Stripe customer data`)
    }
  } catch (error) {
    console.error('❌ Exception in handleCustomerUpdated:', error)
  }
}
```

### customer.deleted

```typescript
export async function handleCustomerDeleted(customer: any) {
  console.log('🗑️ Processing customer.deleted')
  console.log('Customer ID:', customer.id)
  
  try {
    const supabase = createServerServiceRoleClient()
    
    // Find and update subscription records
    const { data: subscriptions, error } = await supabase
      .from('subscriptions')
      .select('id, user_id')
      .eq('stripe_customer_id', customer.id)

    if (error) {
      console.error('❌ Error finding subscriptions for deleted customer:', error)
      return
    }

    if (!subscriptions || subscriptions.length === 0) {
      console.log('No subscriptions found for deleted customer')
      return
    }

    // Update subscriptions to remove customer reference
    const { error: updateError } = await supabase
      .from('subscriptions')
      .update({
        stripe_customer_id: null,
        status: 'canceled',
        cancel_at_period_end: true,
        updated_at: new Date().toISOString()
      })
      .eq('stripe_customer_id', customer.id)

    if (updateError) {
      console.error('❌ Error updating subscriptions for deleted customer:', updateError)
      return
    }

    console.log(`✅ Updated ${subscriptions.length} subscriptions for deleted customer`)
    
    // Optionally notify affected users
    for (const subscription of subscriptions) {
      await notifyUserOfCustomerDeletion(subscription.user_id)
    }
  } catch (error) {
    console.error('❌ Exception in handleCustomerDeleted:', error)
  }
}
```

## Customer Portal Integration

Your codebase includes customer portal functionality:

### Creating Portal Sessions

```typescript
// app/api/billing/create-portal-session/route.ts
export async function POST(request: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    // Get user's Stripe customer ID
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

    // Create portal session with configuration
    const portalSession = await stripe.billingPortal.sessions.create({
      customer: subscription.stripe_customer_id,
      return_url: `${process.env.APP_URL}/billing`,
      configuration: process.env.STRIPE_PORTAL_CONFIGURATION_ID, // Optional: custom portal config
    })

    return new Response(
      JSON.stringify({ url: portalSession.url })
  } catch (error) {
    console.error('Portal session creation failed:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to create portal session' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

### Portal Configuration

Configure the customer portal in Stripe Dashboard or via API:

```typescript
// lib/portal-config.ts
export async function createPortalConfiguration() {
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  const configuration = await stripe.billingPortal.configurations.create({
    business_profile: {
      headline: 'Manage your subscription and billing details',
    },
    features: {
      payment_method_update: {
        enabled: true,
      },
      invoice_history: {
        enabled: true,
      },
      customer_update: {
        enabled: true,
        allowed_updates: ['email', 'name', 'phone', 'address', 'tax_id'],
      },
      subscription_cancel: {
        enabled: true,
        mode: 'at_period_end',
        cancellation_reason: {
          enabled: true,
          options: [
            'too_expensive',
            'missing_features',
            'switched_service',
            'unused',
            'other'
          ]
        }
      },
      subscription_pause: {
        enabled: false, // Disable if not needed
      },
      subscription_update: {
        enabled: true,
        default_allowed_updates: ['price'],
        proration_behavior: 'create_prorations',
      }
    }
  })

  console.log('Portal configuration created:', configuration.id)
  return configuration
}
```

## Customer Data Export

Provide customer data export functionality:

```typescript
// lib/customer-export.ts
export async function exportCustomerData(userId: string) {
  console.log(`📋 Exporting customer data for user ${userId}`)
  
  try {
    const supabase = createServerServiceRoleClient()
    
    // Get user profile
    const { data: user, error: userError } = await supabase
      .from('users')
      .select('*')
      .eq('id', userId)
      .single()

    if (userError || !user) {
      throw new Error('User not found')
    }

    // Get subscription data
    const { data: subscription, error: subError } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('user_id', userId)
      .single()

    // Get usage data
    const { data: usage, error: usageError } = await supabase
      .from('usage_records')
      .select('*')
      .eq('user_id', userId)
      .order('created_at', { ascending: false })
      .limit(1000) // Limit to recent records

    // Get Stripe customer data if available
    let stripeData = null
    if (subscription?.stripe_customer_id) {
      const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
        apiVersion: '2025-08-27.basil'
      })
      
      stripeData = await stripe.customers.retrieve(subscription.stripe_customer_id)
    }

    const exportData = {
      user_profile: user,
      subscription: subscription,
      usage_records: usage || [],
      stripe_customer: stripeData,
      export_timestamp: new Date().toISOString(),
      export_version: '1.0'
    }

    return exportData
  } catch (error) {
    console.error('❌ Error exporting customer data:', error)
    throw error
  }
}

// API endpoint for data export
// app/api/user/export-data/route.ts
export async function GET(request: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    const exportData = await exportCustomerData(user.id)
    
    return new Response(
      JSON.stringify(exportData, {
      headers: {
        'Content-Disposition': `attachment; filename="customer-data-${user.id}.json"`,
        'Content-Type': 'application/json'
      }
    })
  } catch (error) {
    console.error('Data export error:', error)
    return new Response(
      JSON.stringify({ error: 'Export failed' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Customer Deletion and GDPR Compliance

Handle customer deletion requests:

```typescript
// lib/customer-deletion.ts
export async function deleteCustomerData(userId: string, deleteFromStripe: boolean = false) {
  console.log(`🗑️ Deleting customer data for user ${userId}`)
  
  try {
    const supabase = createServerServiceRoleClient()
    
    // Get subscription info before deletion
    const { data: subscription } = await supabase
      .from('subscriptions')
      .select('stripe_customer_id, stripe_subscription_id')
      .eq('user_id', userId)
      .single()

    // Delete from Stripe if requested and customer exists
    if (deleteFromStripe && subscription?.stripe_customer_id) {
      const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
        apiVersion: '2025-08-27.basil'
      })
      
      // Cancel subscription first if it exists
      if (subscription.stripe_subscription_id) {
        await stripe.subscriptions.cancel(subscription.stripe_subscription_id)
      }
      
      // Delete customer from Stripe
      await stripe.customers.del(subscription.stripe_customer_id)
      console.log(`✅ Deleted Stripe customer ${subscription.stripe_customer_id}`)
    }

    // Delete from database (cascade will handle related records)
    const { error: deleteError } = await supabase
      .from('users')
      .delete()
      .eq('id', userId)

    if (deleteError) {
      console.error('❌ Error deleting user data:', deleteError)
      throw deleteError
    }

    console.log(`✅ Customer data deleted for user ${userId}`)
    return true
  } catch (error) {
    console.error('❌ Error deleting customer data:', error)
    throw error
  }
}

// API endpoint for account deletion
// app/api/user/delete-account/route.ts
export async function DELETE(request: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    const { deleteFromStripe = false } = await request.json()
    
    await deleteCustomerData(user.id, deleteFromStripe)
    
    // Sign out user
    await supabase.auth.signOut()
    
    return new Response(
      JSON.stringify({ 
      success: true, 
      message: 'Account deleted successfully' 
    })
  } catch (error) {
    console.error('Account deletion error:', error)
    return new Response(
      JSON.stringify({ error: 'Deletion failed' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Testing Customer Management

### Unit Tests

```typescript
// __tests__/lib/customer-management.test.ts
import { getOrCreateStripeCustomer } from '@/lib/customer-management'

describe('Customer Management', () => {
  it('should return existing customer ID from database', async () => {
    // Mock existing subscription with customer ID
    const mockSubscription = {
      stripeCustomerId: 'cus_existing123'
    }
    
    jest.mocked(getSubscriptionDetails).mockResolvedValue(mockSubscription)
    
    const customerId = await getOrCreateStripeCustomer('user123', 'test@example.com')
    
    expect(customerId).toBe('cus_existing123')
    expect(getSubscriptionDetails).toHaveBeenCalledWith('user123')
  })

  it('should create new customer when none exists', async () => {
    // Mock no existing subscription
    jest.mocked(getSubscriptionDetails).mockResolvedValue(null)
    
    // Mock Stripe customer list (empty)
    const mockStripe = {
      customers: {
        list: jest.fn().mockResolvedValue({ data: [] }),
        create: jest.fn().mockResolvedValue({ id: 'cus_new123' })
      }
    }
    
    const customerId = await getOrCreateStripeCustomer('user123', 'test@example.com')
    
    expect(customerId).toBe('cus_new123')
    expect(mockStripe.customers.create).toHaveBeenCalledWith({
      email: 'test@example.com',
      metadata: {
        userId: 'user123',
        source: 'app_signup',
        created_at: expect.any(String)
      }
    })
  })
})
```

## Next Steps

In the next module, we'll cover plan configuration and how to structure your pricing and feature data for maximum flexibility.

## Key Takeaways

- Use hybrid customer management (database first, Stripe fallback)
- Store customer relationships in your database for fast lookups
- Sync profile changes between your system and Stripe
- Handle customer webhook events for data consistency
- Implement customer portal for self-service billing
- Provide data export functionality for transparency
- Handle customer deletion for GDPR compliance
- Test customer management flows thoroughly
- Use metadata to track customer context and source
- Implement proper error handling for customer operations
