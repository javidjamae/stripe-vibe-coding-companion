# Data Reconciliation: Keeping Database in Sync with Stripe

## Overview

This module covers data reconciliation strategies for maintaining consistency between your database and Stripe, including automated sync processes, conflict resolution, and recovery procedures. Based on production-tested patterns, we'll explore reconciliation approaches that ensure data integrity.

## Why Reconciliation Matters

### Common Sync Issues

**Webhook Delivery Failures:**
- Network timeouts prevent webhook processing
- Server downtime during webhook delivery
- Webhook endpoint errors cause Stripe to stop retrying

**Race Conditions:**
- User action and webhook arrive simultaneously
- Multiple webhooks for same subscription
- API calls made while webhooks are processing

**Manual Changes:**
- Changes made directly in Stripe Dashboard
- Customer portal changes not reflected immediately
- Support team modifications

## Reconciliation Architecture

### Our Recommended Approach

```typescript
// Reconciliation service that runs periodically
export class SubscriptionReconciler {
  private stripe: Stripe
  private supabase: any

  constructor() {
    this.stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })
    this.supabase = createServerServiceRoleClient()
  }

  async reconcileAllSubscriptions(): Promise<{
    processed: number
    synced: number
    errors: string[]
  }> {
    console.log('🔄 Starting full subscription reconciliation...')

    let processed = 0
    let synced = 0
    const errors: string[] = []

    try {
      // Get all subscriptions with Stripe links
      const { data: subscriptions, error } = await this.supabase
        .from('subscriptions')
        .select('*')
        .not('stripe_subscription_id', 'is', null)

      if (error) {
        throw new Error(`Failed to fetch subscriptions: ${error.message}`)
      }

      console.log(`Found ${subscriptions?.length || 0} subscriptions to reconcile`)

      // Process in batches to avoid rate limits
      const batchSize = 10
      for (let i = 0; i < (subscriptions?.length || 0); i += batchSize) {
        const batch = subscriptions.slice(i, i + batchSize)
        
        await Promise.all(
          batch.map(async (subscription) => {
            try {
              const wasUpdated = await this.reconcileSubscription(subscription)
              processed++
              if (wasUpdated) synced++
            } catch (error) {
              errors.push(`Subscription ${subscription.id}: ${error.message}`)
            }
          })
        )

        // Rate limiting pause
        if (i + batchSize < subscriptions.length) {
          await new Promise(resolve => setTimeout(resolve, 1000))
        }
      }

      console.log(`✅ Reconciliation completed: ${synced}/${processed} updated`)

      return { processed, synced, errors }

    } catch (error) {
      console.error('❌ Reconciliation failed:', error)
      return { processed, synced, errors: [error.message] }
    }
  }

  async reconcileSubscription(subscription: any): Promise<boolean> {
    try {
      // Get current state from Stripe
      const stripeSubscription = await this.stripe.subscriptions.retrieve(
        subscription.stripe_subscription_id
      )

      // Compare and identify differences
      const updates: any = {}
      let hasChanges = false

      // Status sync
      if (stripeSubscription.status !== subscription.status) {
        updates.status = stripeSubscription.status
        hasChanges = true
        console.log(`Status sync for ${subscription.id}: ${subscription.status} → ${stripeSubscription.status}`)
      }

      // Cancel flag sync
      if (stripeSubscription.cancel_at_period_end !== subscription.cancel_at_period_end) {
        updates.cancel_at_period_end = stripeSubscription.cancel_at_period_end
        hasChanges = true
        console.log(`Cancel flag sync for ${subscription.id}: ${subscription.cancel_at_period_end} → ${stripeSubscription.cancel_at_period_end}`)
      }

      // Period dates sync
      const stripePeriodStart = new Date(stripeSubscription.current_period_start * 1000).toISOString()
      const stripePeriodEnd = new Date(stripeSubscription.current_period_end * 1000).toISOString()

      if (stripePeriodStart !== subscription.current_period_start) {
        updates.current_period_start = stripePeriodStart
        hasChanges = true
      }

      if (stripePeriodEnd !== subscription.current_period_end) {
        updates.current_period_end = stripePeriodEnd
        hasChanges = true
      }

      // Price ID sync
      const stripeCurrentPrice = stripeSubscription.items.data[0]?.price?.id
      if (stripeCurrentPrice && stripeCurrentPrice !== subscription.stripe_price_id) {
        updates.stripe_price_id = stripeCurrentPrice
        
        // Derive plan ID from price ID
        const planMatch = getPlanByPriceId(stripeCurrentPrice)
        if (planMatch && planMatch.planId !== subscription.plan_id) {
          updates.plan_id = planMatch.planId
        }
        
        hasChanges = true
        console.log(`Price sync for ${subscription.id}: ${subscription.stripe_price_id} → ${stripeCurrentPrice}`)
      }

      // Apply updates if any
      if (hasChanges) {
        updates.updated_at = new Date().toISOString()
        
        const { error } = await this.supabase
          .from('subscriptions')
          .update(updates)
          .eq('id', subscription.id)

        if (error) {
          throw new Error(`Database update failed: ${error.message}`)
        }

        console.log(`✅ Reconciled subscription ${subscription.id} (${Object.keys(updates).length - 1} fields updated)`)
      }

      return hasChanges

    } catch (error) {
      if (error.code === 'resource_missing') {
        // Subscription doesn't exist in Stripe - mark as cancelled
        await this.handleOrphanedSubscription(subscription)
        return true
      }

      console.error(`❌ Failed to reconcile subscription ${subscription.id}:`, error)
      throw error
    }
  }

  private async handleOrphanedSubscription(subscription: any) {
    console.log(`🧹 Handling orphaned subscription: ${subscription.id}`)

    try {
      // Mark subscription as cancelled since it doesn't exist in Stripe
      const { error } = await this.supabase
        .from('subscriptions')
        .update({
          status: 'cancelled',
          cancel_at_period_end: true,
          metadata: {
            ...subscription.metadata,
            orphaned: {
              detected_at: new Date().toISOString(),
              reason: 'stripe_subscription_not_found',
              original_stripe_id: subscription.stripe_subscription_id
            }
          },
          updated_at: new Date().toISOString()
        })
        .eq('id', subscription.id)

      if (error) {
        throw new Error(`Failed to update orphaned subscription: ${error.message}`)
      }

      console.log(`✅ Marked orphaned subscription ${subscription.id} as cancelled`)

    } catch (error) {
      console.error(`❌ Failed to handle orphaned subscription:`, error)
      throw error
    }
  }
}
```

## Automated Reconciliation

### Scheduled Reconciliation Jobs

```typescript
// Automated reconciliation scheduling
export class ReconciliationScheduler {
  async scheduleReconciliation(): Promise<void> {
    console.log('📅 Scheduling reconciliation jobs...')

    const supabase = createServerServiceRoleClient()

    // Schedule daily full reconciliation
    await supabase
      .from('scheduled_tasks')
      .insert({
        task_type: 'full_subscription_reconciliation',
        scheduled_for: this.getNextRunTime('daily').toISOString(),
        status: 'pending',
        metadata: {
          frequency: 'daily',
          created_by: 'reconciliation_scheduler'
        }
      })

    // Schedule hourly quick reconciliation for recent changes
    await supabase
      .from('scheduled_tasks')
      .insert({
        task_type: 'quick_reconciliation',
        scheduled_for: this.getNextRunTime('hourly').toISOString(),
        status: 'pending',
        metadata: {
          frequency: 'hourly',
          scope: 'recent_changes',
          created_by: 'reconciliation_scheduler'
        }
      })

    console.log('✅ Reconciliation jobs scheduled')
  }

  private getNextRunTime(frequency: 'hourly' | 'daily'): Date {
    const now = new Date()
    
    if (frequency === 'hourly') {
      // Next hour at minute 15
      const next = new Date(now)
      next.setHours(now.getHours() + 1, 15, 0, 0)
      return next
    } else {
      // Next day at 3 AM
      const next = new Date(now)
      next.setDate(now.getDate() + 1)
      next.setHours(3, 0, 0, 0)
      return next
    }
  }

  async runQuickReconciliation(): Promise<{
    processed: number
    synced: number
    errors: string[]
  }> {
    console.log('⚡ Running quick reconciliation for recent changes...')

    const supabase = createServerServiceRoleClient()
    const reconciler = new SubscriptionReconciler()

    try {
      // Get subscriptions updated in last 2 hours
      const twoHoursAgo = new Date(Date.now() - 2 * 60 * 60 * 1000)
      
      const { data: recentSubscriptions, error } = await supabase
        .from('subscriptions')
        .select('*')
        .not('stripe_subscription_id', 'is', null)
        .gte('updated_at', twoHoursAgo.toISOString())

      if (error) {
        throw new Error(`Failed to fetch recent subscriptions: ${error.message}`)
      }

      console.log(`Found ${recentSubscriptions?.length || 0} recently updated subscriptions`)

      let processed = 0
      let synced = 0
      const errors: string[] = []

      if (recentSubscriptions) {
        for (const subscription of recentSubscriptions) {
          try {
            const wasUpdated = await reconciler.reconcileSubscription(subscription)
            processed++
            if (wasUpdated) synced++
          } catch (error) {
            errors.push(`Subscription ${subscription.id}: ${error.message}`)
          }
        }
      }

      console.log(`✅ Quick reconciliation completed: ${synced}/${processed} updated`)

      return { processed, synced, errors }

    } catch (error) {
      console.error('❌ Quick reconciliation failed:', error)
      return { processed: 0, synced: 0, errors: [error.message] }
    }
  }
}
```

## Conflict Resolution

### Handling Data Conflicts

```typescript
// Resolve conflicts between database and Stripe
export class ConflictResolver {
  async resolveSubscriptionConflict(
    subscription: any,
    stripeSubscription: any,
    strategy: 'stripe_wins' | 'database_wins' | 'merge' = 'stripe_wins'
  ): Promise<void> {
    console.log(`🔧 Resolving conflict for subscription ${subscription.id} (strategy: ${strategy})`)

    try {
      switch (strategy) {
        case 'stripe_wins':
          await this.syncFromStripe(subscription, stripeSubscription)
          break

        case 'database_wins':
          await this.syncToStripe(subscription, stripeSubscription)
          break

        case 'merge':
          await this.mergeConflictingData(subscription, stripeSubscription)
          break
      }

      console.log(`✅ Conflict resolved using ${strategy} strategy`)

    } catch (error) {
      console.error(`❌ Conflict resolution failed:`, error)
      throw error
    }
  }

  private async syncFromStripe(dbSubscription: any, stripeSubscription: any) {
    // Update database to match Stripe (most common approach)
    const updates = {
      status: stripeSubscription.status,
      cancel_at_period_end: stripeSubscription.cancel_at_period_end,
      current_period_start: new Date(stripeSubscription.current_period_start * 1000).toISOString(),
      current_period_end: new Date(stripeSubscription.current_period_end * 1000).toISOString(),
      stripe_price_id: stripeSubscription.items.data[0]?.price?.id,
      updated_at: new Date().toISOString()
    }

    const { error } = await this.supabase
      .from('subscriptions')
      .update(updates)
      .eq('id', dbSubscription.id)

    if (error) {
      throw new Error(`Database update failed: ${error.message}`)
    }

    console.log('📥 Synced database from Stripe')
  }

  private async syncToStripe(dbSubscription: any, stripeSubscription: any) {
    // Update Stripe to match database (use carefully)
    const updates: any = {}

    if (stripeSubscription.cancel_at_period_end !== dbSubscription.cancel_at_period_end) {
      updates.cancel_at_period_end = dbSubscription.cancel_at_period_end
    }

    if (Object.keys(updates).length > 0) {
      await this.stripe.subscriptions.update(stripeSubscription.id, updates)
      console.log('📤 Synced Stripe from database')
    }
  }

  private async mergeConflictingData(dbSubscription: any, stripeSubscription: any) {
    // Intelligent merge based on timestamps and business logic
    const stripeUpdated = new Date(stripeSubscription.created * 1000)
    const dbUpdated = new Date(dbSubscription.updated_at)

    // Use most recent data for each field
    const updates: any = {}

    // For status, prefer Stripe (authoritative for billing state)
    if (stripeSubscription.status !== dbSubscription.status) {
      updates.status = stripeSubscription.status
    }

    // For cancel flag, use most recent
    if (stripeSubscription.cancel_at_period_end !== dbSubscription.cancel_at_period_end) {
      if (stripeUpdated > dbUpdated) {
        updates.cancel_at_period_end = stripeSubscription.cancel_at_period_end
      }
      // If database is newer, keep database value
    }

    // Always sync period dates from Stripe (authoritative)
    updates.current_period_start = new Date(stripeSubscription.current_period_start * 1000).toISOString()
    updates.current_period_end = new Date(stripeSubscription.current_period_end * 1000).toISOString()

    if (Object.keys(updates).length > 0) {
      updates.updated_at = new Date().toISOString()
      
      const { error } = await this.supabase
        .from('subscriptions')
        .update(updates)
        .eq('id', dbSubscription.id)

      if (error) {
        throw new Error(`Merge update failed: ${error.message}`)
      }

      console.log('🔀 Merged conflicting data')
    }
  }
}
```

## Real-Time Reconciliation

### Webhook-Triggered Reconciliation

```typescript
// Enhanced webhook processing with reconciliation
export async function handleWebhookWithReconciliation(event: any) {
  console.log(`🪝 Processing webhook with reconciliation: ${event.type}`)

  try {
    // Process webhook normally first
    await processWebhookEvent(event)

    // Trigger reconciliation for affected subscription
    const subscriptionId = extractSubscriptionId(event)
    if (subscriptionId) {
      await reconcileSpecificSubscription(subscriptionId)
    }

    console.log(`✅ Webhook processed and reconciled: ${event.id}`)

  } catch (error) {
    console.error(`❌ Webhook processing with reconciliation failed:`, error)
    
    // Even if webhook processing fails, try reconciliation
    try {
      const subscriptionId = extractSubscriptionId(event)
      if (subscriptionId) {
        await reconcileSpecificSubscription(subscriptionId)
        console.log('✅ Reconciliation succeeded despite webhook failure')
      }
    } catch (reconcileError) {
      console.error('❌ Reconciliation also failed:', reconcileError)
    }

    throw error
  }
}

function extractSubscriptionId(event: any): string | null {
  const obj = event.data.object

  // Direct subscription reference
  if (obj.object === 'subscription') {
    return obj.id
  }

  // Invoice events
  if (obj.object === 'invoice' && obj.subscription) {
    return obj.subscription
  }

  // Schedule events
  if (obj.object === 'subscription_schedule') {
    return obj.subscription || obj.released_subscription
  }

  return null
}

async function reconcileSpecificSubscription(stripeSubscriptionId: string) {
  try {
    const supabase = createServerServiceRoleClient()
    
    // Get database subscription
    const { data: dbSubscription } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('stripe_subscription_id', stripeSubscriptionId)
      .single()

    if (!dbSubscription) {
      console.log(`⚠️ No database subscription found for Stripe ID: ${stripeSubscriptionId}`)
      return
    }

    const reconciler = new SubscriptionReconciler()
    await reconciler.reconcileSubscription(dbSubscription)

  } catch (error) {
    console.error('Specific subscription reconciliation failed:', error)
  }
}
```

## Data Validation and Integrity

### Subscription Data Validator

```typescript
// Validate subscription data integrity
export class SubscriptionValidator {
  async validateSubscriptionIntegrity(subscription: any): Promise<{
    valid: boolean
    issues: string[]
    warnings: string[]
  }> {
    const issues: string[] = []
    const warnings: string[] = []

    try {
      // Basic field validation
      if (!subscription.user_id) {
        issues.push('Missing user_id')
      }

      if (!subscription.plan_id) {
        issues.push('Missing plan_id')
      }

      if (!subscription.status) {
        issues.push('Missing status')
      }

      // Status validation
      const validStatuses = ['active', 'cancelled', 'past_due', 'unpaid', 'trialing', 'incomplete', 'incomplete_expired']
      if (subscription.status && !validStatuses.includes(subscription.status)) {
        issues.push(`Invalid status: ${subscription.status}`)
      }

      // Plan configuration validation
      if (subscription.plan_id) {
        const planConfig = getPlanConfig(subscription.plan_id)
        if (!planConfig) {
          issues.push(`Invalid plan_id: ${subscription.plan_id}`)
        }
      }

      // Stripe linkage validation
      if (subscription.stripe_subscription_id) {
        try {
          const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
            apiVersion: '2025-08-27.basil'
          })
          
          await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
        } catch (stripeError) {
          if (stripeError.code === 'resource_missing') {
            issues.push(`Stripe subscription not found: ${subscription.stripe_subscription_id}`)
          } else {
            warnings.push(`Stripe validation failed: ${stripeError.message}`)
          }
        }
      }

      // Price ID validation
      if (subscription.stripe_price_id) {
        const planMatch = getPlanByPriceId(subscription.stripe_price_id)
        if (!planMatch) {
          warnings.push(`Price ID not found in plan configuration: ${subscription.stripe_price_id}`)
        } else if (planMatch.planId !== subscription.plan_id) {
          issues.push(`Plan/Price mismatch: plan=${subscription.plan_id}, price maps to=${planMatch.planId}`)
        }
      }

      // Period validation
      if (subscription.current_period_start && subscription.current_period_end) {
        const start = new Date(subscription.current_period_start)
        const end = new Date(subscription.current_period_end)
        
        if (start >= end) {
          issues.push('Invalid billing period: start date >= end date')
        }

        const now = new Date()
        if (end < now && subscription.status === 'active') {
          warnings.push('Active subscription with past billing period end')
        }
      }

      return {
        valid: issues.length === 0,
        issues,
        warnings
      }

    } catch (error) {
      console.error('Validation failed:', error)
      return {
        valid: false,
        issues: ['Validation process failed'],
        warnings: []
      }
    }
  }

  async validateAllSubscriptions(): Promise<{
    total: number
    valid: number
    invalid: number
    issues: Array<{ subscriptionId: string; issues: string[]; warnings: string[] }>
  }> {
    console.log('🔍 Validating all subscriptions...')

    const supabase = createServerServiceRoleClient()
    
    const { data: subscriptions, error } = await supabase
      .from('subscriptions')
      .select('*')

    if (error) {
      throw new Error(`Failed to fetch subscriptions: ${error.message}`)
    }

    const results = {
      total: subscriptions?.length || 0,
      valid: 0,
      invalid: 0,
      issues: [] as Array<{ subscriptionId: string; issues: string[]; warnings: string[] }>
    }

    if (subscriptions) {
      for (const subscription of subscriptions) {
        const validation = await this.validateSubscriptionIntegrity(subscription)
        
        if (validation.valid) {
          results.valid++
        } else {
          results.invalid++
          results.issues.push({
            subscriptionId: subscription.id,
            issues: validation.issues,
            warnings: validation.warnings
          })
        }
      }
    }

    console.log(`✅ Validation completed: ${results.valid}/${results.total} valid`)
    
    if (results.invalid > 0) {
      console.warn(`⚠️ Found ${results.invalid} invalid subscriptions`)
    }

    return results
  }
}
```

## Manual Reconciliation Tools

### Admin Reconciliation Interface

```typescript
// Admin tools for manual reconciliation
export class AdminReconciliationTools {
  async reconcileUserByEmail(email: string): Promise<{
    success: boolean
    changes: string[]
    errors: string[]
  }> {
    console.log(`🔧 Manual reconciliation for user: ${email}`)

    const changes: string[] = []
    const errors: string[] = []

    try {
      // Find user
      const supabase = createServerServiceRoleClient()
      const { data: authUsers } = await supabase.auth.admin.listUsers()
      const user = authUsers.users.find(u => u.email === email)

      if (!user) {
        errors.push('User not found')
        return { success: false, changes, errors }
      }

      // Get subscription
      const { data: subscription } = await supabase
        .from('subscriptions')
        .select('*')
        .eq('user_id', user.id)
        .single()

      if (!subscription) {
        errors.push('No subscription found')
        return { success: false, changes, errors }
      }

      // Reconcile
      const reconciler = new SubscriptionReconciler()
      const wasUpdated = await reconciler.reconcileSubscription(subscription)

      if (wasUpdated) {
        changes.push('Subscription data synchronized with Stripe')
      } else {
        changes.push('No changes needed - data already in sync')
      }

      return { success: true, changes, errors }

    } catch (error) {
      console.error('Manual reconciliation failed:', error)
      errors.push(error.message)
      return { success: false, changes, errors }
    }
  }

  async forceRefreshFromStripe(subscriptionId: string): Promise<{
    success: boolean
    before: any
    after: any
  }> {
    console.log(`🔄 Force refresh from Stripe for subscription: ${subscriptionId}`)

    try {
      const supabase = createServerServiceRoleClient()

      // Get current database state
      const { data: before } = await supabase
        .from('subscriptions')
        .select('*')
        .eq('id', subscriptionId)
        .single()

      if (!before?.stripe_subscription_id) {
        throw new Error('Subscription not linked to Stripe')
      }

      // Get fresh data from Stripe
      const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
        apiVersion: '2025-08-27.basil'
      })

      const stripeSubscription = await stripe.subscriptions.retrieve(before.stripe_subscription_id)

      // Force update all fields from Stripe
      const updates = {
        status: stripeSubscription.status,
        cancel_at_period_end: stripeSubscription.cancel_at_period_end,
        current_period_start: new Date(stripeSubscription.current_period_start * 1000).toISOString(),
        current_period_end: new Date(stripeSubscription.current_period_end * 1000).toISOString(),
        stripe_price_id: stripeSubscription.items.data[0]?.price?.id,
        updated_at: new Date().toISOString()
      }

      const { data: after, error } = await supabase
        .from('subscriptions')
        .update(updates)
        .eq('id', subscriptionId)
        .select()
        .single()

      if (error) {
        throw new Error(`Force refresh failed: ${error.message}`)
      }

      console.log('✅ Force refresh completed')

      return {
        success: true,
        before: {
          status: before.status,
          cancelAtPeriodEnd: before.cancel_at_period_end,
          stripePriceId: before.stripe_price_id
        },
        after: {
          status: after.status,
          cancelAtPeriodEnd: after.cancel_at_period_end,
          stripePriceId: after.stripe_price_id
        }
      }

    } catch (error) {
      console.error('Force refresh failed:', error)
      throw error
    }
  }
}
```

## Reconciliation Monitoring

### Reconciliation Health Metrics

```typescript
// Monitor reconciliation effectiveness
export class ReconciliationMonitor {
  async getReconciliationMetrics(timeframe: '24h' | '7d' | '30d' = '24h') {
    const hoursBack = timeframe === '24h' ? 24 : timeframe === '7d' ? 168 : 720
    const since = new Date(Date.now() - hoursBack * 60 * 60 * 1000)

    const supabase = createServerServiceRoleClient()

    try {
      // Get reconciliation task results
      const { data: tasks } = await supabase
        .from('scheduled_tasks')
        .select('task_type, status, completed_at, metadata')
        .in('task_type', ['full_subscription_reconciliation', 'quick_reconciliation'])
        .gte('completed_at', since.toISOString())

      // Get subscription inconsistencies
      const inconsistencies = await this.findCurrentInconsistencies()

      return {
        timeframe,
        reconciliationTasks: {
          total: tasks?.length || 0,
          successful: tasks?.filter(t => t.status === 'completed').length || 0,
          failed: tasks?.filter(t => t.status === 'failed').length || 0,
          byType: tasks?.reduce((acc, task) => {
            acc[task.task_type] = (acc[task.task_type] || 0) + 1
            return acc
          }, {} as Record<string, number>) || {}
        },
        currentState: {
          totalSubscriptions: inconsistencies.total,
          inconsistentSubscriptions: inconsistencies.inconsistent,
          consistencyRate: inconsistencies.total > 0 ? 
            ((inconsistencies.total - inconsistencies.inconsistent) / inconsistencies.total) * 100 : 100
        }
      }

    } catch (error) {
      console.error('Failed to get reconciliation metrics:', error)
      return null
    }
  }

  private async findCurrentInconsistencies(): Promise<{
    total: number
    inconsistent: number
    details: Array<{ id: string; issues: string[] }>
  }> {
    const validator = new SubscriptionValidator()
    const validation = await validator.validateAllSubscriptions()

    return {
      total: validation.total,
      inconsistent: validation.invalid,
      details: validation.issues.map(issue => ({
        id: issue.subscriptionId,
        issues: issue.issues
      }))
    }
  }
}
```

## Emergency Reconciliation Procedures

### Emergency Sync Script

```bash
#!/bin/bash
# Emergency reconciliation script

echo "🚨 Emergency subscription reconciliation"
echo "This will sync all subscriptions from Stripe"
read -p "Continue? (y/N): " confirm

if [[ $confirm != "y" && $confirm != "Y" ]]; then
  echo "Cancelled"
  exit 0
fi

echo "🔄 Starting emergency reconciliation..."

# Run reconciliation via API
curl -X POST http://localhost:3000/api/admin/reconcile-all \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ADMIN_TOKEN" \
  -d '{"force": true}' | jq

echo "✅ Emergency reconciliation completed"
```

### Reconciliation API Endpoint

```typescript
// app/api/admin/reconcile-all/route.ts
export async function POST(request: Request) {
  try {
    // Verify admin authorization
    const authHeader = request.headers.get('authorization')
    if (!authHeader || !isValidAdminToken(authHeader)) {
      return new Response(
        JSON.stringify({ error: 'Admin authorization required' }),
        { status: 403 }
      )
    }

    const { force = false } = await request.json()

    console.log(`🔧 Admin reconciliation triggered (force: ${force})`)

    const reconciler = new SubscriptionReconciler()
    const result = await reconciler.reconcileAllSubscriptions()

    // Log admin action
    await logAdminAction('reconcile_all_subscriptions', {
      force,
      result,
      timestamp: new Date().toISOString()
    })

    return new Response(JSON.stringify({
      success: true,
      message: 'Reconciliation completed',
      result
    }))

  } catch (error) {
    console.error('Admin reconciliation failed:', error)
    return new Response(
      JSON.stringify({ error: 'Reconciliation failed' }),
      { status: 500, headers: { 'Content-Type': 'application/json' } }
    )
  }
}

function isValidAdminToken(authHeader: string): boolean {
  const token = authHeader.replace('Bearer ', '')
  return token === process.env.ADMIN_API_TOKEN
}

async function logAdminAction(action: string, metadata: any) {
  try {
    const supabase = createServerServiceRoleClient()
    
    await supabase
      .from('admin_actions')
      .insert({
        action,
        metadata,
        timestamp: new Date().toISOString(),
        ip_address: 'server', // Would get from request in real implementation
        user_agent: 'admin_api'
      })

  } catch (error) {
    console.error('Failed to log admin action:', error)
  }
}
```

## Alternative: Lightweight Reconciliation

For simpler reconciliation needs:

### Basic Sync Function

```typescript
// lib/sync/basic-reconciliation.ts (Alternative approach)
export async function basicSubscriptionSync(userId: string) {
  console.log(`🔄 Basic sync for user ${userId}`)

  try {
    const subscription = await getSubscriptionDetails(userId)
    if (!subscription?.stripe_subscription_id) {
      return { synced: false, reason: 'No Stripe subscription' }
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    const stripeSubscription = await stripe.subscriptions.retrieve(
      subscription.stripe_subscription_id
    )

    // Simple sync: just update status and cancel flag
    const supabase = createServerServiceRoleClient()
    const { error } = await supabase
      .from('subscriptions')
      .update({
        status: stripeSubscription.status,
        cancel_at_period_end: stripeSubscription.cancel_at_period_end,
        updated_at: new Date().toISOString()
      })
      .eq('stripe_subscription_id', subscription.stripe_subscription_id)

    if (error) {
      throw new Error(`Sync failed: ${error.message}`)
    }

    console.log('✅ Basic sync completed')
    return { synced: true }

  } catch (error) {
    console.error('Basic sync failed:', error)
    return { synced: false, reason: error.message }
  }
}
```

## Next Steps

In the next module, we'll cover migration patterns for moving existing customers to new pricing structures.

## Key Takeaways

- **Implement periodic reconciliation** to catch missed webhook events
- **Validate data integrity** regularly with automated checks
- **Handle orphaned subscriptions** gracefully when Stripe data is missing
- **Use Stripe as source of truth** for billing state in most cases
- **Provide manual reconciliation tools** for admin users
- **Monitor reconciliation effectiveness** with health metrics
- **Process reconciliation in batches** to avoid rate limits
- **Log all reconciliation actions** for audit purposes
- **Test reconciliation procedures** thoroughly before production use
- **Have emergency procedures** ready for critical data sync issues
