# Monitoring Setup for Billing Systems

## Overview

This module covers setting up comprehensive monitoring for your Stripe billing system, including webhook monitoring, billing metrics tracking, and alert configuration. Based on production-tested patterns, we'll explore monitoring strategies that ensure reliable billing operations.

## Monitoring Architecture

### Our Recommended Monitoring Stack

```
Application Logs → Log Aggregation → Metrics Collection → Alerting → Dashboard
```

**Key Components:**
1. **Application Logging**: Structured logging in your webhook handlers and APIs
2. **Webhook Monitoring**: Track webhook delivery and processing
3. **Business Metrics**: Monitor subscription lifecycle and revenue
4. **Performance Metrics**: API response times and error rates
5. **Alert Management**: Proactive notification of issues

## Application Logging (Your Actual Patterns)

### Webhook Event Logging

From your actual webhook handlers:

```typescript
// Your actual logging patterns from webhook handlers
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
- Structured logging with emojis for easy scanning
- Log key identifiers (Invoice ID, Subscription ID)
- Log business-relevant data (Amount, Currency, Period dates)
- Clear success/error indicators
- Detailed error logging with context

### API Request Logging

```typescript
// Enhanced logging for your API endpoints
export async function POST(req: Request) {
  const requestId = crypto.randomUUID()
  const startTime = Date.now()
  
  console.log(`🚀 [${requestId}] Upgrade request started`, {
    userId: user.id,
    newPlanId,
    priceId,
    billingInterval
  })

  try {
    // ... your actual upgrade logic ...

    const duration = Date.now() - startTime
    console.log(`✅ [${requestId}] Upgrade completed in ${duration}ms`, {
      from: subscription.plan_id,
      to: newPlanId,
      duration
    })

    return new Response(
      JSON.stringify({ success: true })

  } catch (error) {
    const duration = Date.now() - startTime
    console.error(`❌ [${requestId}] Upgrade failed after ${duration}ms`, {
      error: error.message,
      userId: user.id,
      newPlanId,
      duration
    })

    return new Response(
      JSON.stringify({ error: 'Upgrade failed' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Webhook Monitoring

### Webhook Event Tracking

```typescript
// Enhanced webhook monitoring (builds on your patterns)
export async function processWebhookEvent(event: any) {
  const eventId = event.id
  const eventType = event.type
  const startTime = Date.now()

  console.log(`🪝 [${eventId}] Processing webhook: ${eventType}`)

  try {
    // Store webhook event for monitoring
    await logWebhookEvent(event, 'processing')

    // Process the event (your actual handlers)
    switch (eventType) {
      case 'invoice.payment_succeeded':
        await handleInvoicePaymentPaid(event.data.object)
        break
      case 'subscription_schedule.created':
        await handleSubscriptionScheduleCreated(event.data.object)
        break
      // ... other handlers
    }

    const duration = Date.now() - startTime
    console.log(`✅ [${eventId}] Webhook processed successfully in ${duration}ms`)
    
    await logWebhookEvent(event, 'completed', { duration })

  } catch (error) {
    const duration = Date.now() - startTime
    console.error(`❌ [${eventId}] Webhook processing failed after ${duration}ms:`, error)
    
    await logWebhookEvent(event, 'failed', { 
      duration, 
      error: error.message 
    })

    // Re-throw for Stripe retry logic
    throw error
  }
}

async function logWebhookEvent(event: any, status: 'processing' | 'completed' | 'failed', metadata: any = {}) {
  try {
    const supabase = createServerServiceRoleClient()
    
    await supabase
      .from('webhook_events')
      .upsert({
        event_id: event.id,
        event_type: event.type,
        status,
        stripe_created: new Date(event.created * 1000).toISOString(),
        processed_at: new Date().toISOString(),
        metadata: {
          ...metadata,
          object_id: event.data?.object?.id,
          livemode: event.livemode
        }
      }, {
        onConflict: 'event_id'
      })

  } catch (error) {
    console.error('Failed to log webhook event:', error)
    // Don't fail webhook processing for logging errors
  }
}
```

### Webhook Event Table Schema

```sql
-- Table for tracking webhook events
CREATE TABLE IF NOT EXISTS webhook_events (
  event_id TEXT PRIMARY KEY,
  event_type TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('processing', 'completed', 'failed')),
  stripe_created TIMESTAMPTZ NOT NULL,
  processed_at TIMESTAMPTZ DEFAULT NOW(),
  duration_ms INTEGER,
  error_message TEXT,
  metadata JSONB DEFAULT '{}',
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for monitoring queries
CREATE INDEX idx_webhook_events_type_status ON webhook_events(event_type, status);
CREATE INDEX idx_webhook_events_processed_at ON webhook_events(processed_at);
CREATE INDEX idx_webhook_events_duration ON webhook_events(duration_ms) WHERE duration_ms IS NOT NULL;
```

## Business Metrics Monitoring

### Subscription Lifecycle Metrics

```typescript
// Business metrics collection
export const BillingMetrics = {
  async getSubscriptionMetrics(timeframe: '24h' | '7d' | '30d' = '24h') {
    const hoursBack = timeframe === '24h' ? 24 : timeframe === '7d' ? 168 : 720
    const since = new Date(Date.now() - hoursBack * 60 * 60 * 1000)

    const supabase = createServerServiceRoleClient()

    // New subscriptions
    const { data: newSubs } = await supabase
      .from('subscriptions')
      .select('plan_id, created_at')
      .gte('created_at', since.toISOString())
      .neq('plan_id', 'free')

    // Upgrades (plan changes to higher value)
    const { data: upgrades } = await supabase
      .from('subscriptions')
      .select('metadata, updated_at')
      .gte('updated_at', since.toISOString())
      .not('metadata->upgrade_context', 'is', null)

    // Downgrades (scheduled plan changes to lower value)
    const { data: downgrades } = await supabase
      .from('subscriptions')
      .select('metadata, updated_at')
      .gte('updated_at', since.toISOString())
      .not('metadata->scheduled_change', 'is', null)

    // Cancellations
    const { data: cancellations } = await supabase
      .from('subscriptions')
      .select('plan_id, updated_at')
      .eq('cancel_at_period_end', true)
      .gte('updated_at', since.toISOString())

    return {
      timeframe,
      metrics: {
        newSubscriptions: newSubs?.length || 0,
        upgrades: upgrades?.length || 0,
        downgrades: downgrades?.length || 0,
        cancellations: cancellations?.length || 0,
        byPlan: newSubs?.reduce((acc, sub) => {
          acc[sub.plan_id] = (acc[sub.plan_id] || 0) + 1
          return acc
        }, {} as Record<string, number>) || {}
      }
    }
  },

  async getRevenueMetrics(timeframe: '24h' | '7d' | '30d' = '24h') {
    // This would integrate with Stripe's reporting API
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    const hoursBack = timeframe === '24h' ? 24 : timeframe === '7d' ? 168 : 720
    const since = Math.floor((Date.now() - hoursBack * 60 * 60 * 1000) / 1000)

    try {
      // Get recent invoices
      const invoices = await stripe.invoices.list({
        created: { gte: since },
        status: 'paid',
        limit: 100
      })

      const revenue = invoices.data.reduce((total, invoice) => 
        total + (invoice.amount_paid || 0), 0
      ) / 100 // Convert cents to dollars

      return {
        timeframe,
        revenue,
        invoiceCount: invoices.data.length,
        averageInvoiceValue: invoices.data.length > 0 ? revenue / invoices.data.length : 0
      }

    } catch (error) {
      console.error('Error fetching revenue metrics:', error)
      return null
    }
  }
}
```

## Performance Monitoring

### API Performance Tracking

```typescript
// Middleware for tracking API performance
export function withPerformanceTracking(handler: any) {
  return async (req: Request) => {
    const startTime = Date.now()
    const endpoint = req.url
    const method = req.method

    try {
      const response = await handler(req)
      const duration = Date.now() - startTime
      
      // Log performance metrics
      console.log(`📊 API Performance: ${method} ${endpoint} - ${duration}ms - ${response.status}`)
      
      // Track in metrics system
      await trackAPIMetrics({
        endpoint,
        method,
        duration,
        status: response.status,
        success: response.status < 400
      })

      return response

    } catch (error) {
      const duration = Date.now() - startTime
      
      console.error(`📊 API Error: ${method} ${endpoint} - ${duration}ms - ERROR`)
      
      await trackAPIMetrics({
        endpoint,
        method,
        duration,
        status: 500,
        success: false,
        error: error.message
      })

      throw error
    }
  }
}

async function trackAPIMetrics(metrics: any) {
  // Store metrics for analysis
  try {
    const supabase = createServerServiceRoleClient()
    
    await supabase
      .from('api_metrics')
      .insert({
        endpoint: metrics.endpoint,
        method: metrics.method,
        duration_ms: metrics.duration,
        status_code: metrics.status,
        success: metrics.success,
        error_message: metrics.error,
        timestamp: new Date().toISOString()
      })

  } catch (error) {
    console.error('Failed to track API metrics:', error)
    // Don't fail the request for metrics errors
  }
}
```

### Database Performance Monitoring

```sql
-- Queries for monitoring database performance
-- Slow subscription queries
SELECT 
  query,
  mean_exec_time,
  calls,
  total_exec_time
FROM pg_stat_statements 
WHERE query LIKE '%subscriptions%'
ORDER BY mean_exec_time DESC 
LIMIT 10;

-- Connection monitoring
SELECT 
  state,
  COUNT(*) as connection_count
FROM pg_stat_activity 
WHERE datname = current_database()
GROUP BY state;

-- Table usage statistics
SELECT 
  schemaname,
  tablename,
  n_tup_ins as inserts,
  n_tup_upd as updates,
  n_tup_del as deletes
FROM pg_stat_user_tables 
WHERE tablename IN ('subscriptions', 'users', 'usage_ledger');
```

## Alert Configuration

### Critical Alerts

```typescript
// Critical alert conditions
export const CriticalAlerts = {
  // Webhook processing failures
  webhookFailures: {
    condition: 'webhook failure rate > 5% in 10 minutes',
    action: 'Page on-call engineer immediately',
    escalation: 'Escalate to engineering manager after 15 minutes'
  },

  // Payment processing issues
  paymentFailures: {
    condition: 'checkout session failures > 10% in 10 minutes',
    action: 'Page on-call engineer immediately',
    escalation: 'Escalate to CTO after 30 minutes'
  },

  // Database connectivity
  databaseErrors: {
    condition: 'database connection failures > 5 in 10 minutes',
    action: 'Page infrastructure team immediately',
    escalation: 'Escalate to engineering director after 15 minutes'
  },

  // Stripe API issues
  stripeAPIErrors: {
    condition: 'Stripe API error rate > 10% in 10 minutes',
    action: 'Check Stripe status page and alert team',
    escalation: 'Contact Stripe support if issue persists > 30 minutes'
  }
}
```

### Warning Alerts

```typescript
// Warning alert conditions
export const WarningAlerts = {
  // Performance degradation
  slowResponses: {
    condition: 'API response time > 5s for 50% of requests in 15 minutes',
    action: 'Alert engineering team via Slack'
  },

  // Business metric anomalies
  subscriptionAnomalies: {
    condition: 'New subscriptions < 50% of 7-day average',
    action: 'Alert product and engineering teams'
  },

  // Webhook delays
  webhookDelays: {
    condition: 'Webhook processing time > 10s average in 15 minutes',
    action: 'Alert engineering team'
  },

  // Failed payment trends
  paymentTrends: {
    condition: 'Failed payments > 150% of 7-day average',
    action: 'Alert billing and customer success teams'
  }
}
```

## Monitoring Dashboard Setup

### Key Metrics Dashboard

```typescript
// Dashboard metrics collection
export const DashboardMetrics = {
  async getBillingHealthMetrics() {
    const now = new Date()
    const last24h = new Date(now.getTime() - 24 * 60 * 60 * 1000)
    const last7d = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000)

    const supabase = createServerServiceRoleClient()

    // Subscription metrics
    const { data: subscriptions } = await supabase
      .from('subscriptions')
      .select('plan_id, status, created_at, updated_at')
      .gte('created_at', last7d.toISOString())

    // Webhook metrics
    const { data: webhooks } = await supabase
      .from('webhook_events')
      .select('event_type, status, duration_ms, processed_at')
      .gte('processed_at', last24h.toISOString())

    // API metrics
    const { data: apiMetrics } = await supabase
      .from('api_metrics')
      .select('endpoint, duration_ms, success, timestamp')
      .gte('timestamp', last24h.toISOString())

    return {
      subscriptions: {
        total: subscriptions?.length || 0,
        last24h: subscriptions?.filter(s => 
          new Date(s.created_at) > last24h
        ).length || 0,
        byStatus: subscriptions?.reduce((acc, sub) => {
          acc[sub.status] = (acc[sub.status] || 0) + 1
          return acc
        }, {} as Record<string, number>) || {},
        byPlan: subscriptions?.reduce((acc, sub) => {
          acc[sub.plan_id] = (acc[sub.plan_id] || 0) + 1
          return acc
        }, {} as Record<string, number>) || {}
      },
      
      webhooks: {
        total: webhooks?.length || 0,
        successRate: webhooks?.length ? 
          (webhooks.filter(w => w.status === 'completed').length / webhooks.length) * 100 : 100,
        averageProcessingTime: webhooks?.length ?
          webhooks.reduce((sum, w) => sum + (w.duration_ms || 0), 0) / webhooks.length : 0,
        byType: webhooks?.reduce((acc, webhook) => {
          acc[webhook.event_type] = (acc[webhook.event_type] || 0) + 1
          return acc
        }, {} as Record<string, number>) || {}
      },

      api: {
        total: apiMetrics?.length || 0,
        successRate: apiMetrics?.length ?
          (apiMetrics.filter(m => m.success).length / apiMetrics.length) * 100 : 100,
        averageResponseTime: apiMetrics?.length ?
          apiMetrics.reduce((sum, m) => sum + m.duration_ms, 0) / apiMetrics.length : 0,
        byEndpoint: apiMetrics?.reduce((acc, metric) => {
          acc[metric.endpoint] = (acc[metric.endpoint] || 0) + 1
          return acc
        }, {} as Record<string, number>) || {}
      }
    }
  }
}
```

### Health Check Endpoint

```typescript
// app/api/health/billing/route.ts
export async function GET() {
  try {
    const metrics = await DashboardMetrics.getBillingHealthMetrics()
    
    // Determine overall health
    const isHealthy = 
      metrics.webhooks.successRate > 95 &&
      metrics.api.successRate > 95 &&
      metrics.api.averageResponseTime < 5000

    return new Response(
      JSON.stringify({
      status: isHealthy ? 'healthy' : 'degraded',
      timestamp: new Date().toISOString(),
      metrics
    }, {
      status: isHealthy ? 200 : 503
    })

  } catch (error) {
    return new Response(
      JSON.stringify({
      status: 'unhealthy',
      error: error.message,
      timestamp: new Date().toISOString()
    ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Error Tracking Integration

### Structured Error Logging

```typescript
// Enhanced error tracking for your webhook handlers
export async function handleInvoicePaymentPaid(invoice: any) {
  try {
    // ... your actual processing logic ...

  } catch (error) {
    // Enhanced error logging with context
    const errorContext = {
      handler: 'handleInvoicePaymentPaid',
      invoiceId: invoice.id,
      subscriptionId: invoice.subscription,
      amount: invoice.amount_paid,
      currency: invoice.currency,
      timestamp: new Date().toISOString(),
      environment: process.env.NODE_ENV,
      stripeMode: process.env.STRIPE_SECRET_KEY?.startsWith('sk_test_') ? 'test' : 'live'
    }

    console.error('❌ ERROR: Exception in handleInvoicePaymentPaid:', error)
    console.error('❌ Error context:', errorContext)
    console.error('❌ Error stack:', error instanceof Error ? error.stack : 'No stack trace')

    // Send to error tracking service (if configured)
    if (process.env.ERROR_TRACKING_DSN) {
      await sendToErrorTracking(error, errorContext)
    }

    // Track error metrics
    await trackErrorMetric('webhook_handler_error', {
      handler: 'handleInvoicePaymentPaid',
      errorType: error.constructor.name,
      context: errorContext
    })
  }
}

async function sendToErrorTracking(error: Error, context: any) {
  try {
    // Integration with error tracking service (Sentry, Bugsnag, etc.)
    // This is a placeholder - implement based on your chosen service
    console.log('📤 Sending error to tracking service:', {
      message: error.message,
      context
    })
  } catch (trackingError) {
    console.error('Failed to send error to tracking service:', trackingError)
  }
}
```

## Monitoring Queries and Reports

### Daily Health Report

```sql
-- Daily billing system health report
WITH webhook_stats AS (
  SELECT 
    event_type,
    COUNT(*) as total_events,
    COUNT(*) FILTER (WHERE status = 'completed') as successful_events,
    AVG(duration_ms) as avg_duration_ms,
    MAX(duration_ms) as max_duration_ms
  FROM webhook_events 
  WHERE processed_at > NOW() - INTERVAL '24 hours'
  GROUP BY event_type
),
subscription_stats AS (
  SELECT 
    plan_id,
    COUNT(*) as new_subscriptions
  FROM subscriptions 
  WHERE created_at > NOW() - INTERVAL '24 hours'
  AND plan_id != 'free'
  GROUP BY plan_id
),
api_stats AS (
  SELECT 
    endpoint,
    COUNT(*) as total_requests,
    COUNT(*) FILTER (WHERE success = true) as successful_requests,
    AVG(duration_ms) as avg_response_time
  FROM api_metrics 
  WHERE timestamp > NOW() - INTERVAL '24 hours'
  GROUP BY endpoint
)
SELECT 
  'webhook_health' as metric_type,
  json_build_object(
    'total_events', COALESCE(SUM(total_events), 0),
    'success_rate', CASE 
      WHEN SUM(total_events) > 0 THEN 
        ROUND((SUM(successful_events)::float / SUM(total_events) * 100), 2)
      ELSE 100 
    END,
    'avg_duration_ms', ROUND(AVG(avg_duration_ms), 2)
  ) as metrics
FROM webhook_stats

UNION ALL

SELECT 
  'subscription_growth' as metric_type,
  json_build_object(
    'new_subscriptions', COALESCE(SUM(new_subscriptions), 0),
    'by_plan', json_object_agg(plan_id, new_subscriptions)
  ) as metrics
FROM subscription_stats

UNION ALL

SELECT 
  'api_performance' as metric_type,
  json_build_object(
    'total_requests', COALESCE(SUM(total_requests), 0),
    'success_rate', CASE 
      WHEN SUM(total_requests) > 0 THEN 
        ROUND((SUM(successful_requests)::float / SUM(total_requests) * 100), 2)
      ELSE 100 
    END,
    'avg_response_time', ROUND(AVG(avg_response_time), 2)
  ) as metrics
FROM api_stats;
```

### Weekly Business Report

```sql
-- Weekly business metrics report
SELECT 
  DATE_TRUNC('day', created_at) as date,
  plan_id,
  COUNT(*) as new_subscriptions,
  SUM(CASE WHEN plan_id != 'free' THEN 1 ELSE 0 END) as paid_subscriptions
FROM subscriptions 
WHERE created_at > NOW() - INTERVAL '7 days'
GROUP BY DATE_TRUNC('day', created_at), plan_id
ORDER BY date DESC, plan_id;
```

## Alternative: Advanced Monitoring Setup

For more sophisticated monitoring, you could implement:

### Custom Metrics Collection

```typescript
// lib/monitoring/custom-metrics.ts (Alternative approach)
export class BillingMonitor {
  private metricsBuffer: any[] = []
  private flushInterval: NodeJS.Timeout

  constructor() {
    // Flush metrics every 60 seconds
    this.flushInterval = setInterval(() => {
      this.flushMetrics()
    }, 60000)
  }

  trackEvent(eventType: string, data: any) {
    this.metricsBuffer.push({
      eventType,
      data,
      timestamp: Date.now(),
      environment: process.env.NODE_ENV
    })

    // Flush immediately for critical events
    if (this.isCriticalEvent(eventType)) {
      this.flushMetrics()
    }
  }

  private isCriticalEvent(eventType: string): boolean {
    return [
      'webhook_failure',
      'payment_failure',
      'database_error',
      'stripe_api_error'
    ].includes(eventType)
  }

  private async flushMetrics() {
    if (this.metricsBuffer.length === 0) return

    const metrics = [...this.metricsBuffer]
    this.metricsBuffer = []

    try {
      // Send to monitoring service
      await this.sendMetrics(metrics)
    } catch (error) {
      console.error('Failed to flush metrics:', error)
      // Re-add to buffer for retry
      this.metricsBuffer.unshift(...metrics)
    }
  }

  private async sendMetrics(metrics: any[]) {
    // Send to your monitoring service (DataDog, New Relic, etc.)
    console.log(`📊 Sending ${metrics.length} metrics to monitoring service`)
  }
}

// Global monitor instance
export const billingMonitor = new BillingMonitor()
```

## Next Steps

In the next module, we'll cover security hardening best practices for production billing systems.

## Key Takeaways

- **Implement structured logging** with clear success/error indicators
- **Track webhook events** in database for monitoring and debugging
- **Monitor business metrics** alongside technical metrics
- **Set up critical alerts** for billing system failures
- **Create health check endpoints** for automated monitoring
- **Track API performance** to identify bottlenecks
- **Use consistent logging patterns** across all billing operations
- **Monitor both Stripe and database performance**
- **Set up escalation procedures** for critical issues
- **Generate regular health reports** for proactive monitoring
