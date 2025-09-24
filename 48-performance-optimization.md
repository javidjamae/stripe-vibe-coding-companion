# Performance Optimization for Stripe Integration

## Overview

This module covers performance optimization techniques for Stripe API calls, database queries, and billing operations. Based on production-tested optimization patterns, we'll explore strategies for building fast, scalable billing systems.

## API Performance Optimization

### Stripe API Call Optimization

```typescript
// Optimized Stripe API patterns
export class StripeAPIOptimizer {
  private stripe: Stripe
  private cache: Map<string, { data: any; expires: number }> = new Map()

  constructor() {
    this.stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil',
      // Optimize for performance
      timeout: 10000, // 10 second timeout
      maxNetworkRetries: 2, // Retry failed requests
    })
  }

  // Cache frequently accessed data
  async getCachedPrice(priceId: string): Promise<any> {
    const cacheKey = `price:${priceId}`
    const cached = this.cache.get(cacheKey)

    if (cached && cached.expires > Date.now()) {
      return cached.data
    }

    try {
      const price = await this.stripe.prices.retrieve(priceId)
      
      // Cache for 1 hour (prices rarely change)
      this.cache.set(cacheKey, {
        data: price,
        expires: Date.now() + 60 * 60 * 1000
      })

      return price

    } catch (error) {
      console.error(`Failed to fetch price ${priceId}:`, error)
      throw error
    }
  }

  // Batch operations where possible
  async batchRetrieveCustomers(customerIds: string[]): Promise<any[]> {
    console.log(`📦 Batch retrieving ${customerIds.length} customers`)

    // Stripe doesn't have native batch operations, so we optimize with concurrency
    const concurrencyLimit = 10 // Avoid rate limits
    const results: any[] = []

    for (let i = 0; i < customerIds.length; i += concurrencyLimit) {
      const batch = customerIds.slice(i, i + concurrencyLimit)
      
      const batchPromises = batch.map(async (customerId) => {
        try {
          return await this.stripe.customers.retrieve(customerId)
        } catch (error) {
          console.error(`Failed to retrieve customer ${customerId}:`, error)
          return null
        }
      })

      const batchResults = await Promise.all(batchPromises)
      results.push(...batchResults.filter(Boolean))

      // Rate limiting pause between batches
      if (i + concurrencyLimit < customerIds.length) {
        await new Promise(resolve => setTimeout(resolve, 100))
      }
    }

    console.log(`✅ Batch retrieval completed: ${results.length}/${customerIds.length} successful`)
    return results
  }

  // Optimize subscription updates with minimal data
  async optimizedSubscriptionUpdate(
    subscriptionId: string,
    updates: {
      priceId?: string
      cancelAtPeriodEnd?: boolean
      metadata?: any
    }
  ): Promise<any> {
    console.log(`⚡ Optimized subscription update: ${subscriptionId}`)

    try {
      // Only include fields that are actually changing
      const updateParams: any = {}

      if (updates.priceId) {
        // Get current subscription to find item ID
        const current = await this.stripe.subscriptions.retrieve(subscriptionId, {
          expand: ['items'] // Only expand what we need
        })

        const itemId = current.items.data[0]?.id
        if (!itemId) {
          throw new Error('No subscription item found')
        }

        updateParams.items = [{ id: itemId, price: updates.priceId }]
        updateParams.proration_behavior = 'create_prorations'
      }

      if (updates.cancelAtPeriodEnd !== undefined) {
        updateParams.cancel_at_period_end = updates.cancelAtPeriodEnd
      }

      if (updates.metadata) {
        updateParams.metadata = updates.metadata
      }

      // Only make API call if there are actual updates
      if (Object.keys(updateParams).length === 0) {
        console.log('⚡ No updates needed, skipping API call')
        return null
      }

      const result = await this.stripe.subscriptions.update(subscriptionId, updateParams)
      
      console.log(`✅ Subscription updated with ${Object.keys(updateParams).length} changes`)
      return result

    } catch (error) {
      console.error(`❌ Optimized subscription update failed:`, error)
      throw error
    }
  }
}
```

## Database Query Optimization

### Optimized Subscription Queries (Your Patterns)

```typescript
// Optimize your existing database patterns
export class DatabaseOptimizer {
  // Optimize your RPC function usage
  async getOptimizedSubscriptionDetails(userId: string): Promise<any> {
    const startTime = Date.now()
    
    try {
      const supabase = createServerServiceRoleClient()
      
      // Use your existing RPC function (already optimized)
      const { data, error } = await supabase
        .rpc('get_user_active_subscription', { user_uuid: userId })

      if (error) {
        console.error('RPC call failed:', error)
        
        // Fallback to direct query with optimized select
        const { data: fallback } = await supabase
          .from('subscriptions')
          .select(`
            id,
            user_id,
            stripe_subscription_id,
            stripe_customer_id,
            stripe_price_id,
            plan_id,
            status,
            current_period_start,
            current_period_end,
            cancel_at_period_end,
            metadata
          `) // Only select needed fields
          .eq('user_id', userId)
          .order('updated_at', { ascending: false })
          .limit(1)
          .single()

        const duration = Date.now() - startTime
        console.log(`⚡ Fallback query completed in ${duration}ms`)
        
        return fallback
      }

      const duration = Date.now() - startTime
      console.log(`⚡ RPC query completed in ${duration}ms`)

      return data?.[0] || null

    } catch (error) {
      const duration = Date.now() - startTime
      console.error(`❌ Subscription query failed after ${duration}ms:`, error)
      throw error
    }
  }

  // Optimize usage queries with proper indexing
  async getOptimizedUsageInfo(userId: string): Promise<any> {
    const startTime = Date.now()
    
    try {
      const supabase = createServerServiceRoleClient()

      // Get subscription for billing period
      const subscription = await this.getOptimizedSubscriptionDetails(userId)
      
      // Determine billing period efficiently
      const now = new Date()
      const cycleStart = subscription?.current_period_start 
        ? new Date(subscription.current_period_start)
        : new Date(now.getTime() - 20 * 24 * 60 * 60 * 1000) // 20 days ago for free users

      const cycleEnd = subscription?.current_period_end 
        ? new Date(subscription.current_period_end) 
        : now

      // Optimized usage query with proper indexes
      const { data: usageRows } = await supabase
        .from('usage_ledger')
        .select('billable_minutes') // Only select needed column
        .eq('user_id', userId)
        .gte('created_at', cycleStart.toISOString())
        .lt('created_at', cycleEnd.toISOString())

      const usedMinutes = usageRows?.reduce((sum, row) => sum + (row.billable_minutes || 0), 0) || 0

      // Get plan limits efficiently
      const planConfig = subscription ? getPlanConfig(subscription.plan_id) : null
      const planLimit = planConfig?.includedComputeMinutes ?? 100

      const duration = Date.now() - startTime
      console.log(`⚡ Usage query completed in ${duration}ms`)

      return {
        currentPeriodMinutes: usedMinutes,
        planLimit,
        planType: subscription?.plan_id || 'free',
        canMakeRequest: usedMinutes < planLimit,
        remainingMinutes: Math.max(0, planLimit - usedMinutes)
      }

    } catch (error) {
      const duration = Date.now() - startTime
      console.error(`❌ Usage query failed after ${duration}ms:`, error)
      
      // Return safe fallback
      return {
        currentPeriodMinutes: 0,
        planLimit: 100,
        planType: 'free',
        canMakeRequest: true,
        remainingMinutes: 100
      }
    }
  }
}
```

### Database Index Optimization

```sql
-- Essential indexes for performance (based on your query patterns)

-- Subscription lookups by user (most common query)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_subscriptions_user_id 
ON subscriptions(user_id) 
WHERE status IN ('active', 'trialing', 'past_due');

-- Subscription lookups by Stripe ID (webhook operations)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_subscriptions_stripe_id 
ON subscriptions(stripe_subscription_id) 
WHERE stripe_subscription_id IS NOT NULL;

-- Usage queries by user and date (billing calculations)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_usage_ledger_user_date 
ON usage_ledger(user_id, created_at) 
WHERE billable_minutes > 0;

-- Usage queries by billing period (current period calculations)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_usage_ledger_billing_period 
ON usage_ledger(user_id, period_start, period_end);

-- Webhook event lookups (idempotency checks)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_webhook_events_event_id 
ON webhook_events(event_id);

-- Recent webhook events (monitoring queries)
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_webhook_events_processed_at 
ON webhook_events(processed_at DESC, status);

-- API metrics for performance monitoring
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_api_metrics_timestamp 
ON api_metrics(timestamp DESC, endpoint);
```

### Query Performance Analysis

```sql
-- Analyze query performance for your common patterns
-- Check slow subscription queries
SELECT 
  query,
  calls,
  total_exec_time,
  mean_exec_time,
  rows
FROM pg_stat_statements 
WHERE query LIKE '%subscriptions%'
ORDER BY mean_exec_time DESC 
LIMIT 10;

-- Check usage query performance
SELECT 
  query,
  calls,
  total_exec_time,
  mean_exec_time
FROM pg_stat_statements 
WHERE query LIKE '%usage_ledger%'
ORDER BY total_exec_time DESC 
LIMIT 10;

-- Check index usage
SELECT 
  schemaname,
  tablename,
  indexname,
  idx_scan,
  idx_tup_read,
  idx_tup_fetch
FROM pg_stat_user_indexes 
WHERE tablename IN ('subscriptions', 'usage_ledger')
ORDER BY idx_scan DESC;
```

## Caching Strategies

### Application-Level Caching

```typescript
// Implement caching for expensive operations
export class BillingCache {
  private cache: Map<string, { data: any; expires: number }> = new Map()
  private readonly DEFAULT_TTL = 5 * 60 * 1000 // 5 minutes

  // Cache plan configuration (rarely changes)
  getPlanConfig(planId: string): any {
    const cacheKey = `plan:${planId}`
    const cached = this.cache.get(cacheKey)

    if (cached && cached.expires > Date.now()) {
      return cached.data
    }

    const planConfig = getPlanConfig(planId) // Your existing function
    
    if (planConfig) {
      this.cache.set(cacheKey, {
        data: planConfig,
        expires: Date.now() + 60 * 60 * 1000 // Cache for 1 hour
      })
    }

    return planConfig
  }

  // Cache subscription details with short TTL
  async getCachedSubscription(userId: string): Promise<any> {
    const cacheKey = `subscription:${userId}`
    const cached = this.cache.get(cacheKey)

    if (cached && cached.expires > Date.now()) {
      return cached.data
    }

    const subscription = await getSubscriptionDetails(userId)
    
    if (subscription) {
      this.cache.set(cacheKey, {
        data: subscription,
        expires: Date.now() + this.DEFAULT_TTL
      })
    }

    return subscription
  }

  // Cache usage info with very short TTL
  async getCachedUsage(userId: string): Promise<any> {
    const cacheKey = `usage:${userId}`
    const cached = this.cache.get(cacheKey)

    if (cached && cached.expires > Date.now()) {
      return cached.data
    }

    const usage = await getUsageInfo(userId)
    
    if (usage) {
      this.cache.set(cacheKey, {
        data: usage,
        expires: Date.now() + 2 * 60 * 1000 // Cache for 2 minutes
      })
    }

    return usage
  }

  // Invalidate cache when data changes
  invalidateUserCache(userId: string): void {
    this.cache.delete(`subscription:${userId}`)
    this.cache.delete(`usage:${userId}`)
    console.log(`🗑️ Invalidated cache for user ${userId}`)
  }

  // Cleanup expired cache entries
  cleanupExpiredCache(): void {
    const now = Date.now()
    let cleaned = 0

    for (const [key, value] of this.cache.entries()) {
      if (value.expires <= now) {
        this.cache.delete(key)
        cleaned++
      }
    }

    if (cleaned > 0) {
      console.log(`🧹 Cleaned up ${cleaned} expired cache entries`)
    }
  }
}

// Global cache instance
export const billingCache = new BillingCache()

// Cleanup expired cache every 5 minutes
setInterval(() => {
  billingCache.cleanupExpiredCache()
}, 5 * 60 * 1000)
```

### Response Caching for APIs

```typescript
// Cache API responses for expensive operations
export class APIResponseCache {
  // Cache proration previews (expensive Stripe calls)
  async getCachedProrationPreview(
    subscriptionId: string,
    newPriceId: string
  ): Promise<any> {
    const cacheKey = `proration:${subscriptionId}:${newPriceId}`
    const cached = billingCache.cache.get(cacheKey)

    if (cached && cached.expires > Date.now()) {
      console.log('⚡ Using cached proration preview')
      return cached.data
    }

    console.log('🔌 Fetching fresh proration preview from Stripe')
    
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    try {
      const current = await stripe.subscriptions.retrieve(subscriptionId)
      const currentItem = current.items?.data?.[0]
      
      if (!currentItem) {
        throw new Error('No subscription item found')
      }

      const preview = await stripe.invoices.retrieveUpcoming({
        customer: (current.customer as string),
        subscription: current.id,
        subscription_items: [
          { id: currentItem.id, price: newPriceId }
        ],
        subscription_proration_behavior: 'create_prorations'
      })

      const result = {
        amountDue: (preview.amount_due ?? 0) / 100,
        currency: (preview.currency || 'usd').toUpperCase()
      }

      // Cache for 5 minutes (proration can change)
      billingCache.cache.set(cacheKey, {
        data: result,
        expires: Date.now() + 5 * 60 * 1000
      })

      return result

    } catch (error) {
      console.error('Proration preview failed:', error)
      throw error
    }
  }
}
```

## Database Performance Optimization

### Connection Pooling

```typescript
// Optimize database connections
export class DatabaseConnectionOptimizer {
  private static connectionPool: any = null

  static getOptimizedSupabaseClient() {
    if (!this.connectionPool) {
      this.connectionPool = createClient(
        process.env.SUPABASE_URL!,
        process.env.SUPABASE_SERVICE_ROLE_KEY!,
        {
          db: {
            schema: 'public'
          },
          auth: {
            autoRefreshToken: false,
            persistSession: false
          },
          global: {
            headers: {
              'x-application-name': 'billing-service'
            }
          }
        }
      )
    }

    return this.connectionPool
  }

  // Optimize batch database operations
  async batchUpdateSubscriptions(
    updates: Array<{
      id: string
      changes: any
    }>
  ): Promise<{
    successful: number
    failed: number
    errors: string[]
  }> {
    console.log(`📦 Batch updating ${updates.length} subscriptions`)

    const supabase = this.getOptimizedSupabaseClient()
    let successful = 0
    let failed = 0
    const errors: string[] = []

    // Process in smaller batches to avoid timeouts
    const batchSize = 20
    for (let i = 0; i < updates.length; i += batchSize) {
      const batch = updates.slice(i, i + batchSize)
      
      try {
        // Use Promise.all for concurrent updates within batch
        const batchPromises = batch.map(async (update) => {
          try {
            const { error } = await supabase
              .from('subscriptions')
              .update({
                ...update.changes,
                updated_at: new Date().toISOString()
              })
              .eq('id', update.id)

            if (error) {
              throw new Error(`Update failed: ${error.message}`)
            }

            return { success: true, id: update.id }

          } catch (error) {
            return { success: false, id: update.id, error: error.message }
          }
        })

        const batchResults = await Promise.all(batchPromises)
        
        batchResults.forEach(result => {
          if (result.success) {
            successful++
          } else {
            failed++
            errors.push(`Subscription ${result.id}: ${result.error}`)
          }
        })

      } catch (error) {
        // Batch failed entirely
        batch.forEach(update => {
          failed++
          errors.push(`Subscription ${update.id}: Batch failed - ${error.message}`)
        })
      }
    }

    console.log(`✅ Batch update completed: ${successful}/${updates.length} successful`)
    return { successful, failed, errors }
  }
}
```

### Optimized Usage Aggregation

```typescript
// Optimize usage calculations for better performance
export class UsageOptimizer {
  // Pre-aggregate usage data for faster queries
  async preAggregateUsage(userId: string, periodStart: Date, periodEnd: Date): Promise<void> {
    console.log(`📊 Pre-aggregating usage for user ${userId}`)

    const supabase = createServerServiceRoleClient()

    try {
      // Calculate aggregated usage
      const { data: rawUsage } = await supabase
        .from('usage_ledger')
        .select('metric, billable_minutes, created_at')
        .eq('user_id', userId)
        .gte('created_at', periodStart.toISOString())
        .lt('created_at', periodEnd.toISOString())

      if (!rawUsage || rawUsage.length === 0) {
        return
      }

      // Aggregate by metric
      const aggregated = rawUsage.reduce((acc, record) => {
        if (!acc[record.metric]) {
          acc[record.metric] = {
            total_amount: 0,
            record_count: 0,
            first_usage: record.created_at,
            last_usage: record.created_at
          }
        }

        acc[record.metric].total_amount += record.billable_minutes || 0
        acc[record.metric].record_count += 1
        
        if (record.created_at < acc[record.metric].first_usage) {
          acc[record.metric].first_usage = record.created_at
        }
        
        if (record.created_at > acc[record.metric].last_usage) {
          acc[record.metric].last_usage = record.created_at
        }

        return acc
      }, {} as any)

      // Store aggregated data
      for (const [metric, data] of Object.entries(aggregated)) {
        await supabase
          .from('usage_aggregates')
          .upsert({
            user_id: userId,
            metric: metric,
            period_start: periodStart.toISOString(),
            period_end: periodEnd.toISOString(),
            total_amount: (data as any).total_amount,
            record_count: (data as any).record_count,
            first_usage: (data as any).first_usage,
            last_usage: (data as any).last_usage,
            aggregated_at: new Date().toISOString()
          }, {
            onConflict: 'user_id,metric,period_start'
          })
      }

      console.log(`✅ Pre-aggregated ${Object.keys(aggregated).length} metrics`)

    } catch (error) {
      console.error('Usage pre-aggregation failed:', error)
    }
  }

  // Use pre-aggregated data for faster queries
  async getUsageFromAggregates(userId: string, metric: string = 'compute_minutes'): Promise<number> {
    const supabase = createServerServiceRoleClient()

    try {
      // Get current billing period
      const subscription = await getSubscriptionDetails(userId)
      const periodStart = subscription?.current_period_start 
        ? new Date(subscription.current_period_start)
        : new Date(Date.now() - 20 * 24 * 60 * 60 * 1000)

      // Try to get from aggregates first
      const { data: aggregate } = await supabase
        .from('usage_aggregates')
        .select('total_amount, aggregated_at')
        .eq('user_id', userId)
        .eq('metric', metric)
        .eq('period_start', periodStart.toISOString())
        .single()

      if (aggregate) {
        // Check if aggregate is recent (within last hour)
        const aggregatedAt = new Date(aggregate.aggregated_at)
        const isRecent = Date.now() - aggregatedAt.getTime() < 60 * 60 * 1000

        if (isRecent) {
          console.log('⚡ Using pre-aggregated usage data')
          return aggregate.total_amount
        }
      }

      // Fall back to real-time calculation
      console.log('🔌 Calculating usage in real-time')
      const usage = await getUsageInfo(userId)
      return usage?.currentPeriodMinutes || 0

    } catch (error) {
      console.error('Optimized usage query failed:', error)
      return 0
    }
  }
}
```

## API Response Time Optimization

### Response Time Monitoring

```typescript
// Monitor and optimize API response times
export class ResponseTimeOptimizer {
  private static responseTimeTargets = {
    '/api/billing/subscription': 500,    // 500ms target
    '/api/billing/upgrade': 2000,        // 2s target (Stripe calls)
    '/api/billing/usage': 300,           // 300ms target
    '/api/billing/create-checkout-session': 1500 // 1.5s target
  }

  static async measureAndOptimize<T>(
    endpoint: string,
    operation: () => Promise<T>
  ): Promise<T> {
    const startTime = Date.now()
    
    try {
      const result = await operation()
      const duration = Date.now() - startTime
      
      // Log performance
      console.log(`⚡ ${endpoint}: ${duration}ms`)
      
      // Check against targets
      const target = this.responseTimeTargets[endpoint] || 1000
      if (duration > target) {
        console.warn(`⚠️ Slow response: ${endpoint} took ${duration}ms (target: ${target}ms)`)
        
        // Track slow responses for optimization
        await this.trackSlowResponse(endpoint, duration, target)
      }

      return result

    } catch (error) {
      const duration = Date.now() - startTime
      console.error(`❌ ${endpoint} failed after ${duration}ms:`, error)
      throw error
    }
  }

  private static async trackSlowResponse(endpoint: string, duration: number, target: number) {
    try {
      const supabase = createServerServiceRoleClient()
      
      await supabase
        .from('performance_issues')
        .insert({
          endpoint,
          duration_ms: duration,
          target_ms: target,
          slowness_factor: duration / target,
          timestamp: new Date().toISOString(),
          environment: process.env.NODE_ENV
        })

    } catch (error) {
      console.error('Failed to track slow response:', error)
    }
  }
}

// Usage in your APIs
export async function POST(req: Request) {
  return await ResponseTimeOptimizer.measureAndOptimize(
    '/api/billing/upgrade',
    async () => {
      // Your actual upgrade logic
      const body = await req.json()
      const result = await processUpgrade(body)
      return new Response(JSON.stringify(result))
    }
  )
}
```

## Webhook Performance Optimization

### Optimized Webhook Processing

```typescript
// Optimize webhook processing for high throughput
export class WebhookOptimizer {
  // Process webhooks asynchronously for better performance
  async processWebhookAsync(event: any): Promise<void> {
    console.log(`🪝 Async processing webhook: ${event.type}`)

    try {
      // Queue webhook for background processing
      await this.queueWebhookEvent(event)
      
      // Return immediately to Stripe (acknowledge receipt)
      console.log(`✅ Webhook ${event.id} queued for processing`)

    } catch (error) {
      console.error(`❌ Failed to queue webhook ${event.id}:`, error)
      throw error
    }
  }

  private async queueWebhookEvent(event: any): Promise<void> {
    const supabase = createServerServiceRoleClient()

    // Store event for background processing
    await supabase
      .from('webhook_queue')
      .insert({
        event_id: event.id,
        event_type: event.type,
        event_data: event,
        status: 'queued',
        queued_at: new Date().toISOString(),
        attempts: 0
      })
  }

  // Background worker to process queued webhooks
  async processWebhookQueue(): Promise<void> {
    console.log('🔄 Processing webhook queue...')

    const supabase = createServerServiceRoleClient()

    try {
      // Get queued webhooks
      const { data: queuedEvents } = await supabase
        .from('webhook_queue')
        .select('*')
        .eq('status', 'queued')
        .order('queued_at', { ascending: true })
        .limit(10) // Process in small batches

      if (!queuedEvents || queuedEvents.length === 0) {
        return
      }

      console.log(`📦 Processing ${queuedEvents.length} queued webhooks`)

      for (const queuedEvent of queuedEvents) {
        try {
          // Mark as processing
          await supabase
            .from('webhook_queue')
            .update({
              status: 'processing',
              processing_started_at: new Date().toISOString(),
              attempts: queuedEvent.attempts + 1
            })
            .eq('id', queuedEvent.id)

          // Process the webhook event
          await this.processWebhookEvent(queuedEvent.event_data)

          // Mark as completed
          await supabase
            .from('webhook_queue')
            .update({
              status: 'completed',
              completed_at: new Date().toISOString()
            })
            .eq('id', queuedEvent.id)

          console.log(`✅ Processed queued webhook: ${queuedEvent.event_id}`)

        } catch (error) {
          console.error(`❌ Failed to process queued webhook ${queuedEvent.event_id}:`, error)

          // Handle retry logic
          const maxAttempts = 3
          if (queuedEvent.attempts + 1 >= maxAttempts) {
            // Mark as failed after max attempts
            await supabase
              .from('webhook_queue')
              .update({
                status: 'failed',
                failed_at: new Date().toISOString(),
                error_message: error.message
              })
              .eq('id', queuedEvent.id)
          } else {
            // Reset to queued for retry
            await supabase
              .from('webhook_queue')
              .update({
                status: 'queued',
                processing_started_at: null
              })
              .eq('id', queuedEvent.id)
          }
        }
      }

    } catch (error) {
      console.error('❌ Webhook queue processing failed:', error)
    }
  }

  private async processWebhookEvent(event: any): Promise<void> {
    // Your actual webhook processing logic
    switch (event.type) {
      case 'invoice.payment_succeeded':
        await handleInvoicePaymentPaid(event.data.object)
        break
      case 'subscription_schedule.created':
        await handleSubscriptionScheduleCreated(event.data.object)
        break
      // ... other event handlers
    }
  }
}
```

## Frontend Performance Optimization

### Optimized Billing Page Loading

```typescript
// Optimize your billing page data loading
export class BillingPageOptimizer {
  // Load data in parallel instead of sequentially
  async loadBillingDataOptimized(userId: string, billingInterval: 'month' | 'year' = 'month') {
    console.log(`⚡ Loading billing data optimized for user ${userId}`)

    const startTime = Date.now()

    try {
      // Load all data in parallel (your current pattern is already good)
      const [plansData, subscriptionData, usageData] = await Promise.all([
        getAvailablePlans(billingInterval),
        billingCache.getCachedSubscription(userId), // Use cached version
        billingCache.getCachedUsage(userId)         // Use cached version
      ])

      const duration = Date.now() - startTime
      console.log(`✅ Billing data loaded in ${duration}ms`)

      return {
        plans: plansData,
        subscription: subscriptionData,
        usage: usageData,
        loadTime: duration
      }

    } catch (error) {
      const duration = Date.now() - startTime
      console.error(`❌ Billing data loading failed after ${duration}ms:`, error)
      throw error
    }
  }

  // Lightweight interval switching (your current pattern)
  async switchBillingInterval(newInterval: 'month' | 'year') {
    console.log(`⚡ Lightweight interval switch to ${newInterval}`)

    // Only reload plans, keep subscription and usage data
    const plansData = await getAvailablePlans(newInterval)
    
    return {
      plans: plansData,
      // Don't reload subscription and usage - they don't change with interval
    }
  }
}
```

## Performance Monitoring

### Performance Metrics Collection

```typescript
// Track performance metrics for optimization
export class PerformanceMonitor {
  async trackAPIPerformance(
    endpoint: string,
    method: string,
    duration: number,
    success: boolean,
    metadata: any = {}
  ): Promise<void> {
    try {
      const supabase = createServerServiceRoleClient()
      
      await supabase
        .from('api_performance_metrics')
        .insert({
          endpoint,
          method,
          duration_ms: duration,
          success,
          timestamp: new Date().toISOString(),
          metadata,
          environment: process.env.NODE_ENV
        })

    } catch (error) {
      console.error('Failed to track API performance:', error)
      // Don't fail the request for metrics errors
    }
  }

  async getPerformanceReport(timeframe: '1h' | '24h' | '7d' = '24h') {
    const hoursBack = timeframe === '1h' ? 1 : timeframe === '24h' ? 24 : 168
    const since = new Date(Date.now() - hoursBack * 60 * 60 * 1000)

    const supabase = createServerServiceRoleClient()

    try {
      const { data: metrics } = await supabase
        .from('api_performance_metrics')
        .select('endpoint, duration_ms, success, timestamp')
        .gte('timestamp', since.toISOString())

      if (!metrics || metrics.length === 0) {
        return { noData: true }
      }

      // Aggregate by endpoint
      const byEndpoint = metrics.reduce((acc, metric) => {
        if (!acc[metric.endpoint]) {
          acc[metric.endpoint] = {
            totalRequests: 0,
            successfulRequests: 0,
            totalDuration: 0,
            minDuration: Infinity,
            maxDuration: 0
          }
        }

        const endpoint = acc[metric.endpoint]
        endpoint.totalRequests++
        
        if (metric.success) {
          endpoint.successfulRequests++
        }

        endpoint.totalDuration += metric.duration_ms
        endpoint.minDuration = Math.min(endpoint.minDuration, metric.duration_ms)
        endpoint.maxDuration = Math.max(endpoint.maxDuration, metric.duration_ms)

        return acc
      }, {} as any)

      // Calculate averages and rates
      Object.values(byEndpoint).forEach((endpoint: any) => {
        endpoint.averageDuration = Math.round(endpoint.totalDuration / endpoint.totalRequests)
        endpoint.successRate = Math.round((endpoint.successfulRequests / endpoint.totalRequests) * 100)
        endpoint.minDuration = endpoint.minDuration === Infinity ? 0 : endpoint.minDuration
      })

      return {
        timeframe,
        totalRequests: metrics.length,
        overallSuccessRate: Math.round((metrics.filter(m => m.success).length / metrics.length) * 100),
        averageResponseTime: Math.round(metrics.reduce((sum, m) => sum + m.duration_ms, 0) / metrics.length),
        byEndpoint
      }

    } catch (error) {
      console.error('Failed to generate performance report:', error)
      return { error: error.message }
    }
  }
}
```

## Alternative: Basic Performance Optimization

For simpler performance needs:

### Basic Caching Implementation

```typescript
// lib/performance/simple-cache.ts (Alternative approach)
const simpleCache = new Map<string, { data: any; expires: number }>()

export function withSimpleCache<T>(
  key: string,
  ttlMs: number,
  operation: () => Promise<T>
): Promise<T> {
  return new Promise(async (resolve, reject) => {
    // Check cache
    const cached = simpleCache.get(key)
    if (cached && cached.expires > Date.now()) {
      resolve(cached.data)
      return
    }

    try {
      // Execute operation
      const result = await operation()
      
      // Cache result
      simpleCache.set(key, {
        data: result,
        expires: Date.now() + ttlMs
      })

      resolve(result)

    } catch (error) {
      reject(error)
    }
  })
}

// Usage
export async function getSubscriptionWithCache(userId: string) {
  return withSimpleCache(
    `subscription:${userId}`,
    5 * 60 * 1000, // 5 minute cache
    () => getSubscriptionDetails(userId)
  )
}
```

## Performance Testing

### Load Testing for Billing APIs

```typescript
// Performance tests for billing operations
describe('Billing API Performance', () => {
  it('should handle concurrent checkout session creation', async () => {
    const startTime = Date.now()
    const concurrentRequests = 20

    // Create multiple checkout sessions concurrently
    const promises = Array.from({ length: concurrentRequests }, (_, i) =>
      fetch('/api/billing/create-checkout-session', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          userId: `test_user_${i}`,
          planId: 'starter',
          successUrl: 'https://example.com/success',
          cancelUrl: 'https://example.com/cancel'
        })
      })
    )

    const responses = await Promise.all(promises)
    const endTime = Date.now()

    // Verify all succeeded
    responses.forEach((response, index) => {
      expect(response.status).toBe(200)
    })

    // Performance assertion
    const totalDuration = endTime - startTime
    const averagePerRequest = totalDuration / concurrentRequests

    console.log(`Performance: ${concurrentRequests} requests in ${totalDuration}ms (avg: ${averagePerRequest}ms per request)`)
    
    // Should complete within reasonable time
    expect(averagePerRequest).toBeLessThan(3000) // 3 seconds per request average
  })

  it('should handle subscription queries efficiently', async () => {
    const startTime = Date.now()

    // Query subscription details 100 times
    const promises = Array.from({ length: 100 }, () =>
      getSubscriptionDetails('test_user_id')
    )

    await Promise.all(promises)
    const endTime = Date.now()

    const totalDuration = endTime - startTime
    const averagePerQuery = totalDuration / 100

    console.log(`Database performance: 100 queries in ${totalDuration}ms (avg: ${averagePerQuery}ms per query)`)
    
    // Should be fast due to indexing
    expect(averagePerQuery).toBeLessThan(100) // 100ms per query average
  })
})
```

## Next Steps

Congratulations! You've completed the Stripe Implementation Mastery Course. You now have comprehensive knowledge of building production-ready Stripe billing systems with advanced patterns for subscriptions, webhooks, testing, and operations.

## Key Takeaways

- **Cache expensive operations** like plan configuration and Stripe API calls
- **Optimize database queries** with proper indexing and RPC functions
- **Use connection pooling** for better database performance
- **Monitor response times** and alert on performance degradation
- **Process webhooks asynchronously** for high-throughput scenarios
- **Pre-aggregate usage data** for faster billing calculations
- **Batch operations** where possible to reduce API overhead
- **Test performance** under realistic load conditions
- **Track performance metrics** for continuous optimization
- **Use caching strategically** with appropriate TTL values
