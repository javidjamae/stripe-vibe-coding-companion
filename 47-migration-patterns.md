# Migration Patterns for Existing Customers

## Overview

This module covers migration strategies for moving existing customers to new pricing structures, plan configurations, or billing systems. We'll explore safe migration patterns, rollback procedures, and customer communication strategies for successful transitions.

## Migration Strategy Overview

### Types of Migrations

**Pricing Migrations:**
- New price points for existing plans
- Additional billing intervals (adding annual to monthly-only plans)
- Currency changes or tax adjustments

**Plan Structure Migrations:**
- New plan tiers or features
- Consolidating or splitting existing plans
- Usage limit adjustments

**System Migrations:**
- Moving from another billing provider to Stripe
- Upgrading Stripe API versions
- Database schema changes

## Safe Migration Principles

### Our Recommended Migration Approach

```typescript
// Migration framework for safe customer transitions
export class CustomerMigration {
  async planMigration(
    migrationId: string,
    description: string,
    customerFilter: (subscription: any) => boolean,
    migrationLogic: (subscription: any) => Promise<any>
  ): Promise<{
    planned: number
    successful: number
    failed: number
    errors: string[]
  }> {
    console.log(`🚀 Starting migration: ${migrationId}`)
    console.log(`Description: ${description}`)

    const supabase = createServerServiceRoleClient()
    
    // Create migration record
    const { data: migration, error: migrationError } = await supabase
      .from('customer_migrations')
      .insert({
        migration_id: migrationId,
        description,
        status: 'running',
        started_at: new Date().toISOString()
      })
      .select()
      .single()

    if (migrationError) {
      throw new Error(`Failed to create migration record: ${migrationError.message}`)
    }

    let planned = 0
    let successful = 0
    let failed = 0
    const errors: string[] = []

    try {
      // Get all subscriptions
      const { data: subscriptions, error } = await supabase
        .from('subscriptions')
        .select('*')

      if (error) {
        throw new Error(`Failed to fetch subscriptions: ${error.message}`)
      }

      // Filter customers for migration
      const targetSubscriptions = subscriptions?.filter(customerFilter) || []
      planned = targetSubscriptions.length

      console.log(`📊 Migration scope: ${planned} subscriptions`)

      // Process in small batches
      const batchSize = 5
      for (let i = 0; i < targetSubscriptions.length; i += batchSize) {
        const batch = targetSubscriptions.slice(i, i + batchSize)
        
        console.log(`Processing batch ${Math.floor(i/batchSize) + 1}/${Math.ceil(targetSubscriptions.length/batchSize)}`)

        for (const subscription of batch) {
          try {
            // Apply migration logic
            await migrationLogic(subscription)
            
            // Record successful migration
            await this.recordMigrationResult(migration.id, subscription.id, 'success')
            successful++
            
            console.log(`✅ Migrated subscription ${subscription.id}`)

          } catch (error) {
            // Record failed migration
            await this.recordMigrationResult(migration.id, subscription.id, 'failed', error.message)
            failed++
            errors.push(`Subscription ${subscription.id}: ${error.message}`)
            
            console.error(`❌ Failed to migrate subscription ${subscription.id}:`, error)
          }
        }

        // Rate limiting pause between batches
        if (i + batchSize < targetSubscriptions.length) {
          await new Promise(resolve => setTimeout(resolve, 2000))
        }
      }

      // Update migration record
      await supabase
        .from('customer_migrations')
        .update({
          status: failed === 0 ? 'completed' : 'completed_with_errors',
          completed_at: new Date().toISOString(),
          planned_count: planned,
          successful_count: successful,
          failed_count: failed
        })
        .eq('id', migration.id)

      console.log(`✅ Migration completed: ${successful}/${planned} successful`)

      return { planned, successful, failed, errors }

    } catch (error) {
      // Mark migration as failed
      await supabase
        .from('customer_migrations')
        .update({
          status: 'failed',
          completed_at: new Date().toISOString(),
          error_message: error.message
        })
        .eq('id', migration.id)

      console.error('❌ Migration failed:', error)
      throw error
    }
  }

  private async recordMigrationResult(
    migrationId: string,
    subscriptionId: string,
    status: 'success' | 'failed',
    errorMessage?: string
  ) {
    const supabase = createServerServiceRoleClient()

    await supabase
      .from('migration_results')
      .insert({
        migration_id: migrationId,
        subscription_id: subscriptionId,
        status,
        error_message: errorMessage,
        processed_at: new Date().toISOString()
      })
  }
}
```

## Common Migration Scenarios

### Scenario 1: Adding Annual Billing to Monthly-Only Plans

```typescript
// Migration: Add annual billing options to existing monthly subscribers
export async function migrateToAnnualBilling() {
  const migration = new CustomerMigration()

  await migration.planMigration(
    'add_annual_billing_2024',
    'Add annual billing options to monthly subscribers',
    
    // Filter: Monthly subscribers on paid plans
    (subscription) => {
      const planConfig = getPlanConfig(subscription.plan_id)
      const isMonthlyPaid = planConfig && 
        !planConfig.isFree && 
        subscription.stripe_price_id === planConfig.monthly?.stripePriceId

      return isMonthlyPaid && planConfig.annual?.stripePriceId
    },

    // Migration logic: Create subscription schedule for annual option
    async (subscription) => {
      const planConfig = getPlanConfig(subscription.plan_id)
      if (!planConfig?.annual?.stripePriceId) {
        throw new Error('No annual price configured')
      }

      // Add metadata about annual option availability
      const supabase = createServerServiceRoleClient()
      await supabase
        .from('subscriptions')
        .update({
          metadata: {
            ...subscription.metadata,
            annual_option_available: {
              annual_price_id: planConfig.annual.stripePriceId,
              annual_price_cents: planConfig.annual.priceCents,
              savings_percent: Math.round((1 - (planConfig.annual.priceCents / (planConfig.monthly.priceCents * 12))) * 100),
              available_since: new Date().toISOString()
            }
          },
          updated_at: new Date().toISOString()
        })
        .eq('id', subscription.id)

      // Send notification about annual option
      await sendAnnualOptionNotification(subscription.user_id, {
        planName: planConfig.name,
        monthlyCost: planConfig.monthly.priceCents / 100,
        annualCost: planConfig.annual.priceCents / 100,
        annualSavings: (planConfig.monthly.priceCents * 12 - planConfig.annual.priceCents) / 100
      })

      return { addedAnnualOption: true }
    }
  )
}

async function sendAnnualOptionNotification(userId: string, data: any) {
  try {
    const { data: user } = await supabaseAdmin.auth.admin.getUserById(userId)
    
    if (user.user?.email) {
      await sendEmail({
        to: user.user.email,
        subject: `Save money with annual billing - ${data.planName}`,
        template: 'annual_option_available',
        data: {
          firstName: user.user.user_metadata?.first_name || 'Valued Customer',
          ...data,
          upgradeUrl: `${process.env.APP_URL}/billing?highlight=annual`
        }
      })
    }

  } catch (error) {
    console.error('Failed to send annual option notification:', error)
  }
}
```

### Scenario 2: Price Increase Migration

```typescript
// Migration: Implement price increases with grandfathering
export async function migratePriceIncrease() {
  const migration = new CustomerMigration()

  await migration.planMigration(
    'price_increase_2024',
    'Implement price increases with grandfathering for existing customers',
    
    // Filter: Active subscribers on old pricing
    (subscription) => {
      return subscription.status === 'active' && 
             subscription.plan_id === 'starter' &&
             new Date(subscription.created_at) < new Date('2024-01-01') // Existing customers
    },

    // Migration logic: Grandfather existing customers
    async (subscription) => {
      const supabase = createServerServiceRoleClient()

      // Add grandfathering metadata
      await supabase
        .from('subscriptions')
        .update({
          metadata: {
            ...subscription.metadata,
            grandfathered_pricing: {
              original_price_id: subscription.stripe_price_id,
              grandfathered_at: new Date().toISOString(),
              grandfathered_until: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toISOString(), // 1 year
              reason: 'price_increase_2024'
            }
          },
          updated_at: new Date().toISOString()
        })
        .eq('id', subscription.id)

      // Send grandfathering notification
      await sendGrandfatheringNotification(subscription.user_id, {
        planName: getPlanConfig(subscription.plan_id)?.name,
        currentPrice: getPlanPrice(subscription.plan_id, 'month') / 100,
        newPrice: 25.00, // New price
        grandfatheredUntil: new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toLocaleDateString()
      })

      return { grandfathered: true }
    }
  )
}

async function sendGrandfatheringNotification(userId: string, data: any) {
  try {
    const { data: user } = await supabaseAdmin.auth.admin.getUserById(userId)
    
    if (user.user?.email) {
      await sendEmail({
        to: user.user.email,
        subject: `Your ${data.planName} pricing is protected`,
        template: 'grandfathered_pricing',
        data: {
          firstName: user.user.user_metadata?.first_name || 'Valued Customer',
          ...data
        }
      })
    }

  } catch (error) {
    console.error('Failed to send grandfathering notification:', error)
  }
}
```

### Scenario 3: Plan Consolidation Migration

```typescript
// Migration: Consolidate legacy plans into new structure
export async function consolidateLegacyPlans() {
  const migration = new CustomerMigration()

  const planMappings = {
    'legacy_basic': 'starter',
    'legacy_premium': 'pro',
    'legacy_enterprise': 'scale'
  }

  await migration.planMigration(
    'consolidate_legacy_plans_2024',
    'Migrate legacy plan customers to new plan structure',
    
    // Filter: Customers on legacy plans
    (subscription) => {
      return Object.keys(planMappings).includes(subscription.plan_id)
    },

    // Migration logic: Update to new plan
    async (subscription) => {
      const newPlanId = planMappings[subscription.plan_id as keyof typeof planMappings]
      if (!newPlanId) {
        throw new Error(`No mapping found for plan ${subscription.plan_id}`)
      }

      const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
        apiVersion: '2025-08-27.basil'
      })

      // Get new price ID
      const currentInterval = getBillingIntervalFromPriceId(subscription.stripe_price_id)
      const newPriceId = getStripePriceId(newPlanId, currentInterval)
      
      if (!newPriceId) {
        throw new Error(`No price ID found for ${newPlanId} ${currentInterval}`)
      }

      // Update subscription in Stripe
      const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
      const itemId = stripeSubscription.items.data[0].id

      await stripe.subscriptions.update(subscription.stripe_subscription_id, {
        items: [{ id: itemId, price: newPriceId }],
        proration_behavior: 'none' // No charge for plan consolidation
      })

      // Update database
      const supabase = createServerServiceRoleClient()
      await supabase
        .from('subscriptions')
        .update({
          plan_id: newPlanId,
          stripe_price_id: newPriceId,
          metadata: {
            ...subscription.metadata,
            plan_migration: {
              from_plan: subscription.plan_id,
              to_plan: newPlanId,
              migrated_at: new Date().toISOString(),
              migration_type: 'legacy_consolidation'
            }
          },
          updated_at: new Date().toISOString()
        })
        .eq('id', subscription.id)

      // Send migration notification
      await sendPlanMigrationNotification(subscription.user_id, {
        fromPlan: subscription.plan_id,
        toPlan: newPlanId,
        features: 'same features, new plan name',
        noChargeChange: true
      })

      return { 
        fromPlan: subscription.plan_id, 
        toPlan: newPlanId,
        priceChange: false
      }
    }
  )
}
```

## Gradual Migration Strategies

### Phased Migration Approach

```typescript
// Implement gradual migration in phases
export class PhasedMigration {
  async executePhase(
    phaseId: string,
    percentage: number, // Percentage of customers to migrate
    migrationLogic: (subscription: any) => Promise<any>
  ): Promise<{
    phase: string
    targetCount: number
    migrated: number
    errors: string[]
  }> {
    console.log(`📊 Executing migration phase: ${phaseId} (${percentage}% of customers)`)

    const supabase = createServerServiceRoleClient()
    
    try {
      // Get eligible subscriptions
      const { data: allSubscriptions, error } = await supabase
        .from('subscriptions')
        .select('*')
        .eq('status', 'active')
        .is('migration_phase', null) // Not yet migrated

      if (error) {
        throw new Error(`Failed to fetch subscriptions: ${error.message}`)
      }

      // Calculate phase size
      const totalEligible = allSubscriptions?.length || 0
      const phaseSize = Math.ceil(totalEligible * (percentage / 100))
      
      // Select random subset for this phase
      const shuffled = allSubscriptions?.sort(() => 0.5 - Math.random()) || []
      const phaseSubscriptions = shuffled.slice(0, phaseSize)

      console.log(`🎯 Phase target: ${phaseSize} subscriptions`)

      let migrated = 0
      const errors: string[] = []

      // Process phase subscriptions
      for (const subscription of phaseSubscriptions) {
        try {
          await migrationLogic(subscription)
          
          // Mark as migrated
          await supabase
            .from('subscriptions')
            .update({
              migration_phase: phaseId,
              migrated_at: new Date().toISOString()
            })
            .eq('id', subscription.id)

          migrated++

        } catch (error) {
          errors.push(`Subscription ${subscription.id}: ${error.message}`)
          console.error(`❌ Phase migration failed for ${subscription.id}:`, error)
        }
      }

      console.log(`✅ Phase ${phaseId} completed: ${migrated}/${phaseSize} migrated`)

      return {
        phase: phaseId,
        targetCount: phaseSize,
        migrated,
        errors
      }

    } catch (error) {
      console.error(`❌ Phase ${phaseId} failed:`, error)
      throw error
    }
  }

  async runFullPhasedMigration(migrationConfig: {
    id: string
    description: string
    phases: Array<{ id: string; percentage: number; delayDays: number }>
    migrationLogic: (subscription: any) => Promise<any>
  }) {
    console.log(`🚀 Starting phased migration: ${migrationConfig.id}`)

    const results = []

    for (const phase of migrationConfig.phases) {
      console.log(`📅 Starting phase ${phase.id} (${phase.percentage}%)`)
      
      const phaseResult = await this.executePhase(
        phase.id,
        phase.percentage,
        migrationConfig.migrationLogic
      )

      results.push(phaseResult)

      // Wait before next phase
      if (phase.delayDays > 0) {
        console.log(`⏳ Waiting ${phase.delayDays} days before next phase...`)
        
        // In real implementation, you'd schedule the next phase
        // For demo, we'll just log the delay
        console.log(`📅 Next phase scheduled for ${new Date(Date.now() + phase.delayDays * 24 * 60 * 60 * 1000).toISOString()}`)
      }
    }

    return {
      migrationId: migrationConfig.id,
      phases: results,
      totalMigrated: results.reduce((sum, phase) => sum + phase.migrated, 0),
      totalErrors: results.reduce((sum, phase) => sum + phase.errors.length, 0)
    }
  }
}
```

## Rollback Procedures

### Safe Migration Rollback

```typescript
// Rollback migration if issues are detected
export class MigrationRollback {
  async rollbackMigration(migrationId: string): Promise<{
    rolledBack: number
    failed: number
    errors: string[]
  }> {
    console.log(`🔄 Rolling back migration: ${migrationId}`)

    const supabase = createServerServiceRoleClient()
    
    try {
      // Get migration results
      const { data: migrationResults, error } = await supabase
        .from('migration_results')
        .select('subscription_id')
        .eq('migration_id', migrationId)
        .eq('status', 'success')

      if (error) {
        throw new Error(`Failed to fetch migration results: ${error.message}`)
      }

      console.log(`Found ${migrationResults?.length || 0} subscriptions to rollback`)

      let rolledBack = 0
      let failed = 0
      const errors: string[] = []

      if (migrationResults) {
        for (const result of migrationResults) {
          try {
            await this.rollbackSubscription(result.subscription_id)
            rolledBack++
            
            // Mark as rolled back
            await supabase
              .from('migration_results')
              .update({
                status: 'rolled_back',
                rolled_back_at: new Date().toISOString()
              })
              .eq('migration_id', migrationId)
              .eq('subscription_id', result.subscription_id)

          } catch (error) {
            failed++
            errors.push(`Subscription ${result.subscription_id}: ${error.message}`)
          }
        }
      }

      // Update migration status
      await supabase
        .from('customer_migrations')
        .update({
          status: 'rolled_back',
          rolled_back_at: new Date().toISOString(),
          rollback_summary: {
            rolled_back: rolledBack,
            failed: failed,
            errors: errors.length
          }
        })
        .eq('migration_id', migrationId)

      console.log(`✅ Rollback completed: ${rolledBack} subscriptions rolled back`)

      return { rolledBack, failed, errors }

    } catch (error) {
      console.error('❌ Rollback failed:', error)
      throw error
    }
  }

  private async rollbackSubscription(subscriptionId: string): Promise<void> {
    const supabase = createServerServiceRoleClient()

    try {
      // Get subscription with migration metadata
      const { data: subscription } = await supabase
        .from('subscriptions')
        .select('*')
        .eq('id', subscriptionId)
        .single()

      if (!subscription) {
        throw new Error('Subscription not found')
      }

      const migrationData = subscription.metadata?.plan_migration
      if (!migrationData) {
        throw new Error('No migration data found')
      }

      // Restore original plan
      const originalPlanId = migrationData.from_plan
      const originalPriceId = await this.getOriginalPriceId(originalPlanId, subscription)

      if (!originalPriceId) {
        throw new Error(`Cannot determine original price ID for plan ${originalPlanId}`)
      }

      // Update in Stripe
      const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
        apiVersion: '2025-08-27.basil'
      })

      const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
      const itemId = stripeSubscription.items.data[0].id

      await stripe.subscriptions.update(subscription.stripe_subscription_id, {
        items: [{ id: itemId, price: originalPriceId }],
        proration_behavior: 'none' // No charge for rollback
      })

      // Update database
      const { plan_migration, ...otherMetadata } = subscription.metadata || {}
      
      await supabase
        .from('subscriptions')
        .update({
          plan_id: originalPlanId,
          stripe_price_id: originalPriceId,
          metadata: {
            ...otherMetadata,
            rollback: {
              rolled_back_at: new Date().toISOString(),
              rolled_back_from: migrationData.to_plan,
              rollback_reason: 'migration_rollback'
            }
          },
          migration_phase: null,
          updated_at: new Date().toISOString()
        })
        .eq('id', subscriptionId)

      console.log(`✅ Rolled back subscription ${subscriptionId} to ${originalPlanId}`)

    } catch (error) {
      console.error(`❌ Failed to rollback subscription ${subscriptionId}:`, error)
      throw error
    }
  }

  private async getOriginalPriceId(planId: string, subscription: any): Promise<string | null> {
    // Determine original price ID based on current billing interval
    const currentInterval = getBillingIntervalFromPriceId(subscription.stripe_price_id)
    return getStripePriceId(planId, currentInterval)
  }
}
```

## Customer Communication During Migration

### Migration Notification Templates

```typescript
// Email templates for migration communications
export const MigrationEmailTemplates = {
  migration_announcement: {
    subject: 'Important Update: Changes to Your {{planName}} Plan',
    html: `
      <h2>Hi {{firstName}},</h2>
      
      <p>We're writing to let you know about an upcoming change to your {{planName}} subscription.</p>
      
      <h3>What's Changing</h3>
      <p>{{changeDescription}}</p>
      
      <h3>When</h3>
      <p>This change will take effect on {{effectiveDate}}.</p>
      
      <h3>What You Need to Do</h3>
      <p>{{actionRequired}}</p>
      
      <p>Questions? Reply to this email or visit our help center.</p>
      
      <p>Thanks for being a valued customer!</p>
      
      <p>The Team</p>
    `
  },

  migration_completed: {
    subject: 'Your {{planName}} Plan Has Been Updated',
    html: `
      <h2>Hi {{firstName}},</h2>
      
      <p>Your plan migration has been completed successfully!</p>
      
      <h3>What Changed</h3>
      <ul>
        <li>Plan: {{fromPlan}} → {{toPlan}}</li>
        <li>Features: {{featureChanges}}</li>
        <li>Billing: {{billingChanges}}</li>
      </ul>
      
      <h3>Your Next Steps</h3>
      <p>{{nextSteps}}</p>
      
      <p>View your updated subscription: <a href="{{billingUrl}}">Manage Billing</a></p>
      
      <p>Questions? We're here to help!</p>
      
      <p>The Team</p>
    `
  },

  migration_failed: {
    subject: 'Action Required: Plan Update Issue',
    html: `
      <h2>Hi {{firstName}},</h2>
      
      <p>We encountered an issue while updating your {{planName}} subscription.</p>
      
      <h3>What Happened</h3>
      <p>{{errorDescription}}</p>
      
      <h3>What We're Doing</h3>
      <p>Our team has been notified and is working to resolve this issue. Your current subscription remains active and unchanged.</p>
      
      <h3>What You Can Do</h3>
      <p>If you'd like to help us resolve this faster, please:</p>
      <ol>
        <li>Check that your payment method is up to date</li>
        <li>Reply to this email with any recent account changes</li>
      </ol>
      
      <p>We'll email you once the issue is resolved.</p>
      
      <p>Sorry for the inconvenience!</p>
      
      <p>The Team</p>
    `
  }
}
```

### Migration Communication Strategy

```typescript
// Manage customer communication during migrations
export class MigrationCommunication {
  async sendMigrationAnnouncement(
    migrationId: string,
    customerSegment: string,
    announcementData: any
  ): Promise<{
    sent: number
    failed: number
    errors: string[]
  }> {
    console.log(`📧 Sending migration announcement: ${migrationId} to ${customerSegment}`)

    const supabase = createServerServiceRoleClient()
    
    // Get target customers
    const { data: subscriptions } = await supabase
      .from('subscriptions')
      .select('user_id, plan_id')
      .eq('status', 'active')
      // Add customer segment filtering logic here

    if (!subscriptions) {
      return { sent: 0, failed: 0, errors: ['No customers found'] }
    }

    let sent = 0
    let failed = 0
    const errors: string[] = []

    // Send in batches to avoid rate limits
    const batchSize = 50
    for (let i = 0; i < subscriptions.length; i += batchSize) {
      const batch = subscriptions.slice(i, i + batchSize)
      
      for (const subscription of batch) {
        try {
          const { data: user } = await supabase.auth.admin.getUserById(subscription.user_id)
          
          if (user.user?.email) {
            await sendEmail({
              to: user.user.email,
              subject: announcementData.subject,
              template: 'migration_announcement',
              data: {
                firstName: user.user.user_metadata?.first_name || 'Valued Customer',
                planName: getPlanConfig(subscription.plan_id)?.name,
                ...announcementData
              }
            })

            sent++
          }

        } catch (error) {
          failed++
          errors.push(`User ${subscription.user_id}: ${error.message}`)
        }
      }

      // Rate limiting pause
      await new Promise(resolve => setTimeout(resolve, 1000))
    }

    console.log(`✅ Migration announcement sent: ${sent} successful, ${failed} failed`)

    return { sent, failed, errors }
  }
}
```

## Migration Testing

### Migration Testing Framework

```typescript
// Test migrations safely before production
export class MigrationTester {
  async testMigration(
    migrationLogic: (subscription: any) => Promise<any>,
    testSubscriptions: any[]
  ): Promise<{
    successful: number
    failed: number
    results: any[]
  }> {
    console.log(`🧪 Testing migration with ${testSubscriptions.length} test subscriptions`)

    let successful = 0
    let failed = 0
    const results: any[] = []

    for (const subscription of testSubscriptions) {
      try {
        const result = await migrationLogic(subscription)
        successful++
        results.push({
          subscriptionId: subscription.id,
          status: 'success',
          result
        })

        console.log(`✅ Test migration successful for ${subscription.id}`)

      } catch (error) {
        failed++
        results.push({
          subscriptionId: subscription.id,
          status: 'failed',
          error: error.message
        })

        console.error(`❌ Test migration failed for ${subscription.id}:`, error)
      }
    }

    console.log(`🧪 Migration test completed: ${successful}/${testSubscriptions.length} successful`)

    return { successful, failed, results }
  }

  async createTestSubscriptions(count: number = 5): Promise<any[]> {
    console.log(`🌱 Creating ${count} test subscriptions for migration testing`)

    const testSubscriptions = []

    for (let i = 0; i < count; i++) {
      const email = `migration-test-${Date.now()}-${i}@example.com`
      
      try {
        const result = await seedStarterUserWithStripeSubscription(email)
        if (result.ok) {
          testSubscriptions.push({
            id: result.subscriptionId,
            userId: result.userId,
            email: email
          })
        }

      } catch (error) {
        console.error(`Failed to create test subscription ${i}:`, error)
      }
    }

    console.log(`✅ Created ${testSubscriptions.length} test subscriptions`)
    return testSubscriptions
  }

  async cleanupTestSubscriptions(testSubscriptions: any[]): Promise<void> {
    console.log(`🧹 Cleaning up ${testSubscriptions.length} test subscriptions`)

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    for (const testSub of testSubscriptions) {
      try {
        // Cancel Stripe subscription
        await stripe.subscriptions.cancel(testSub.id)
        
        // Delete from database would cascade via foreign keys
        console.log(`✅ Cleaned up test subscription ${testSub.id}`)

      } catch (error) {
        console.error(`❌ Failed to cleanup test subscription ${testSub.id}:`, error)
      }
    }
  }
}
```

## Migration Monitoring

### Migration Progress Tracking

```typescript
// Monitor migration progress and health
export class MigrationMonitor {
  async getMigrationStatus(migrationId: string): Promise<{
    migration: any
    progress: {
      planned: number
      completed: number
      failed: number
      percentage: number
    }
    recentErrors: string[]
    nextPhase?: string
  }> {
    const supabase = createServerServiceRoleClient()

    try {
      // Get migration record
      const { data: migration } = await supabase
        .from('customer_migrations')
        .select('*')
        .eq('migration_id', migrationId)
        .single()

      if (!migration) {
        throw new Error('Migration not found')
      }

      // Get migration results
      const { data: results } = await supabase
        .from('migration_results')
        .select('status, error_message')
        .eq('migration_id', migrationId)

      const planned = migration.planned_count || 0
      const completed = results?.filter(r => r.status === 'success').length || 0
      const failed = results?.filter(r => r.status === 'failed').length || 0
      const percentage = planned > 0 ? Math.round((completed / planned) * 100) : 0

      const recentErrors = results
        ?.filter(r => r.status === 'failed')
        .map(r => r.error_message)
        .slice(0, 10) || []

      return {
        migration: {
          id: migration.migration_id,
          description: migration.description,
          status: migration.status,
          startedAt: migration.started_at,
          completedAt: migration.completed_at
        },
        progress: {
          planned,
          completed,
          failed,
          percentage
        },
        recentErrors,
        nextPhase: this.determineNextPhase(migration)
      }

    } catch (error) {
      console.error('Failed to get migration status:', error)
      throw error
    }
  }

  private determineNextPhase(migration: any): string | undefined {
    // Logic to determine next migration phase
    if (migration.status === 'running') {
      return 'Continue current migration'
    }

    if (migration.status === 'completed_with_errors') {
      return 'Review errors and retry failed subscriptions'
    }

    if (migration.status === 'completed') {
      return 'Migration complete - monitor for issues'
    }

    return undefined
  }

  async alertOnMigrationIssues(migrationId: string): Promise<void> {
    const status = await this.getMigrationStatus(migrationId)

    // Alert on high failure rate
    const failureRate = status.progress.planned > 0 ? 
      (status.progress.failed / status.progress.planned) * 100 : 0

    if (failureRate > 10) { // More than 10% failure rate
      await sendAlert({
        type: 'migration_high_failure_rate',
        severity: 'high',
        message: `Migration ${migrationId} has ${failureRate.toFixed(1)}% failure rate`,
        data: status
      })
    }

    // Alert on stalled migration
    if (status.migration.status === 'running') {
      const startedAt = new Date(status.migration.startedAt)
      const hoursRunning = (Date.now() - startedAt.getTime()) / (60 * 60 * 1000)

      if (hoursRunning > 24) { // Running for more than 24 hours
        await sendAlert({
          type: 'migration_stalled',
          severity: 'medium',
          message: `Migration ${migrationId} has been running for ${hoursRunning.toFixed(1)} hours`,
          data: status
        })
      }
    }
  }
}
```

## Alternative: Simple Migration Approach

For basic migration needs:

### One-Time Migration Script

```typescript
// lib/migrations/simple-migration.ts (Alternative approach)
export async function simpleCustomerMigration(
  description: string,
  customerFilter: (sub: any) => boolean,
  updateFunction: (sub: any) => any
) {
  console.log(`🔄 Simple migration: ${description}`)

  const supabase = createServerServiceRoleClient()
  
  try {
    // Get target subscriptions
    const { data: subscriptions } = await supabase
      .from('subscriptions')
      .select('*')

    const targets = subscriptions?.filter(customerFilter) || []
    console.log(`Found ${targets.length} subscriptions to migrate`)

    let updated = 0
    const errors = []

    for (const subscription of targets) {
      try {
        const updates = updateFunction(subscription)
        
        await supabase
          .from('subscriptions')
          .update({
            ...updates,
            updated_at: new Date().toISOString()
          })
          .eq('id', subscription.id)

        updated++

      } catch (error) {
        errors.push(`${subscription.id}: ${error.message}`)
      }
    }

    console.log(`✅ Migration completed: ${updated}/${targets.length} updated`)
    
    return { updated, total: targets.length, errors }

  } catch (error) {
    console.error('Simple migration failed:', error)
    throw error
  }
}

// Usage example
await simpleCustomerMigration(
  'Add annual option metadata to monthly subscribers',
  (sub) => sub.plan_id === 'starter' && !sub.metadata?.annual_option_available,
  (sub) => ({
    metadata: {
      ...sub.metadata,
      annual_option_available: {
        available_since: new Date().toISOString()
      }
    }
  })
)
```

## Next Steps

In the next module, we'll cover performance optimization techniques for Stripe API calls and database queries.

## Key Takeaways

- **Plan migrations carefully** with clear rollback procedures
- **Use phased rollouts** to minimize risk and catch issues early
- **Test migrations thoroughly** with realistic test data before production
- **Communicate proactively** with customers about changes
- **Monitor migration progress** and alert on issues
- **Implement rollback procedures** for when migrations go wrong
- **Use Stripe as source of truth** for billing state during reconciliation
- **Handle orphaned data gracefully** when Stripe records are missing
- **Log all migration actions** for audit and debugging purposes
- **Validate data integrity** before and after migrations
