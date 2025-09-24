# Webhook Monitoring and Debugging

## Overview

This module covers comprehensive webhook monitoring, debugging techniques, and operational practices for maintaining healthy webhook systems in production. We'll explore monitoring patterns, alerting strategies, and debugging tools.

## Webhook Monitoring Architecture

### Monitoring Stack

```
Webhook Endpoint → Metrics Collection → Alerting → Dashboard → Incident Response
```

### Key Metrics to Monitor

1. **Reliability Metrics**: Success rate, failure rate, retry counts
2. **Performance Metrics**: Processing time, throughput, queue depth
3. **Security Metrics**: Invalid signatures, rate limit hits, suspicious events
4. **Business Metrics**: Revenue events, subscription changes, customer actions

## Comprehensive Webhook Logging

### Enhanced Webhook Logger

```typescript
// lib/webhook-logger.ts
export class WebhookLogger {
  private readonly supabase = createServerServiceRoleClient()

  /**
   * Log comprehensive webhook event data
   */
  public async logWebhookEvent(params: {
    eventId: string
    eventType: string
    requestId: string
    ip: string
    userAgent?: string
    processingStarted: string
    metadata?: Record<string, any>
  }): Promise<void> {
    
    try {
      await this.supabase
        .from('webhook_logs')
        .insert({
          stripe_event_id: params.eventId,
          event_type: params.eventType,
          request_id: params.requestId,
          client_ip: params.ip,
          user_agent: params.userAgent,
          processing_started_at: params.processingStarted,
          status: 'processing',
          metadata: params.metadata || {},
          created_at: new Date().toISOString()
        })

      console.log(`📝 Logged webhook event: ${params.eventId}`)
    } catch (error) {
      console.error('❌ Failed to log webhook event:', error)
    }
  }

  /**
   * Log webhook processing success
   */
  public async logWebhookSuccess(params: {
    eventId: string
    requestId: string
    processingTime: number
    result?: any
  }): Promise<void> {
    
    try {
      await this.supabase
        .from('webhook_logs')
        .update({
          status: 'completed',
          processing_time_ms: params.processingTime,
          processing_result: params.result,
          completed_at: new Date().toISOString()
        })
        .eq('stripe_event_id', params.eventId)
        .eq('request_id', params.requestId)

      // Update metrics
      await this.updateSuccessMetrics(params.eventId, params.processingTime)

    } catch (error) {
      console.error('❌ Failed to log webhook success:', error)
    }
  }

  /**
   * Log webhook processing error
   */
  public async logWebhookError(params: {
    eventId?: string
    requestId: string
    error: string
    processingTime: number
    retryable?: boolean
    stackTrace?: string
  }): Promise<void> {
    
    try {
      const logData = {
        status: 'failed',
        error_message: params.error,
        processing_time_ms: params.processingTime,
        retryable: params.retryable || false,
        stack_trace: params.stackTrace,
        failed_at: new Date().toISOString()
      }

      if (params.eventId) {
        await this.supabase
          .from('webhook_logs')
          .update(logData)
          .eq('stripe_event_id', params.eventId)
          .eq('request_id', params.requestId)
      } else {
        // Log error without event (e.g., signature verification failure)
        await this.supabase
          .from('webhook_logs')
          .insert({
            request_id: params.requestId,
            ...logData,
            created_at: new Date().toISOString()
          })
      }

      // Update error metrics
      await this.updateErrorMetrics(params.error, params.retryable || false)

    } catch (error) {
      console.error('❌ Failed to log webhook error:', error)
    }
  }

  /**
   * Log security events
   */
  public async logSecurityEvent(params: {
    type: 'missing_signature' | 'invalid_signature' | 'rate_limit' | 'suspicious_event'
    ip: string
    requestId: string
    error?: string
    severity: 'low' | 'medium' | 'high' | 'critical'
    metadata?: Record<string, any>
  }): Promise<void> {
    
    try {
      await this.supabase
        .from('webhook_security_logs')
        .insert({
          security_event_type: params.type,
          client_ip: params.ip,
          request_id: params.requestId,
          error_message: params.error,
          severity: params.severity,
          metadata: params.metadata || {},
          created_at: new Date().toISOString()
        })

      // Send immediate alert for critical security events
      if (params.severity === 'critical') {
        await this.sendSecurityAlert(params)
      }

    } catch (error) {
      console.error('❌ Failed to log security event:', error)
    }
  }

  private async updateSuccessMetrics(eventId: string, processingTime: number): Promise<void> {
    // Update metrics in monitoring system
    await monitoringService.increment('webhook.success', 1, {
      event_type: eventId.split('_')[0] // Extract event type from ID
    })

    await monitoringService.histogram('webhook.processing_time', processingTime, {
      event_type: eventId.split('_')[0]
    })
  }

  private async updateErrorMetrics(error: string, retryable: boolean): Promise<void> {
    await monitoringService.increment('webhook.error', 1, {
      retryable: retryable.toString(),
      error_type: this.categorizeError(error)
    })
  }

  private categorizeError(error: string): string {
    const errorLower = error.toLowerCase()
    
    if (errorLower.includes('database')) return 'database'
    if (errorLower.includes('network')) return 'network'
    if (errorLower.includes('timeout')) return 'timeout'
    if (errorLower.includes('validation')) return 'validation'
    if (errorLower.includes('business')) return 'business_logic'
    
    return 'unknown'
  }

  private async sendSecurityAlert(params: any): Promise<void> {
    try {
      await alertingService.sendAlert({
        title: 'Critical Webhook Security Event',
        description: `${params.type} from IP ${params.ip}`,
        severity: 'critical',
        context: params
      })
    } catch (error) {
      console.error('❌ Failed to send security alert:', error)
    }
  }
}
```

## Real-Time Monitoring Dashboard

### Webhook Metrics API

```typescript
// app/api/admin/webhook-metrics/route.ts
export async function GET(request: Request) {
  try {
    // Verify admin access
    const hasAdminAccess = await verifyAdminAccess(request)
    if (!hasAdminAccess) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    const url = new URL(request.url)
    const timeRange = url.searchParams.get('range') || '24h' // 1h, 24h, 7d, 30d
    const eventType = url.searchParams.get('eventType') // Optional filter

    const metrics = await getWebhookMetrics(timeRange, eventType)

    return new Response(
      JSON.stringify(metrics)

  } catch (error) {
    console.error('Webhook metrics error:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to fetch metrics' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}

async function getWebhookMetrics(
  timeRange: string,
  eventType?: string | null
): Promise<any> {
  
  const supabase = createServerServiceRoleClient()
  const timeRangeMs = parseTimeRange(timeRange)
  const startTime = new Date(Date.now() - timeRangeMs).toISOString()

  // Build query
  let query = supabase
    .from('webhook_logs')
    .select('*')
    .gte('created_at', startTime)

  if (eventType) {
    query = query.eq('event_type', eventType)
  }

  const { data: logs, error } = await query

  if (error) {
    throw error
  }

  // Calculate metrics
  const totalEvents = logs?.length || 0
  const successfulEvents = logs?.filter(log => log.status === 'completed').length || 0
  const failedEvents = logs?.filter(log => log.status === 'failed').length || 0
  const processingEvents = logs?.filter(log => log.status === 'processing').length || 0

  const successRate = totalEvents > 0 ? (successfulEvents / totalEvents) * 100 : 0
  const failureRate = totalEvents > 0 ? (failedEvents / totalEvents) * 100 : 0

  // Processing time metrics
  const completedLogs = logs?.filter(log => log.processing_time_ms) || []
  const processingTimes = completedLogs.map(log => log.processing_time_ms)
  
  const avgProcessingTime = processingTimes.length > 0
    ? processingTimes.reduce((sum, time) => sum + time, 0) / processingTimes.length
    : 0

  const p95ProcessingTime = calculatePercentile(processingTimes, 95)
  const p99ProcessingTime = calculatePercentile(processingTimes, 99)

  // Event type breakdown
  const eventTypeBreakdown = logs?.reduce((acc, log) => {
    const type = log.event_type || 'unknown'
    acc[type] = (acc[type] || 0) + 1
    return acc
  }, {} as Record<string, number>) || {}

  // Error breakdown
  const errorBreakdown = logs?.filter(log => log.status === 'failed')
    .reduce((acc, log) => {
      const errorType = categorizeError(log.error_message || 'unknown')
      acc[errorType] = (acc[errorType] || 0) + 1
      return acc
    }, {} as Record<string, number>) || {}

  // Timeline data (hourly buckets)
  const timelineData = generateTimelineData(logs || [], timeRangeMs)

  return {
    summary: {
      totalEvents,
      successfulEvents,
      failedEvents,
      processingEvents,
      successRate,
      failureRate
    },
    performance: {
      avgProcessingTime,
      p95ProcessingTime,
      p99ProcessingTime
    },
    breakdown: {
      eventTypes: eventTypeBreakdown,
      errors: errorBreakdown
    },
    timeline: timelineData,
    healthStatus: determineHealthStatus(successRate, avgProcessingTime, processingEvents)
  }
}

function parseTimeRange(range: string): number {
  switch (range) {
    case '1h': return 60 * 60 * 1000
    case '24h': return 24 * 60 * 60 * 1000
    case '7d': return 7 * 24 * 60 * 60 * 1000
    case '30d': return 30 * 24 * 60 * 60 * 1000
    default: return 24 * 60 * 60 * 1000
  }
}

function calculatePercentile(values: number[], percentile: number): number {
  if (values.length === 0) return 0
  
  const sorted = values.sort((a, b) => a - b)
  const index = Math.ceil((percentile / 100) * sorted.length) - 1
  return sorted[index] || 0
}

function determineHealthStatus(
  successRate: number,
  avgProcessingTime: number,
  processingEvents: number
): 'healthy' | 'warning' | 'critical' {
  
  if (successRate < 95 || avgProcessingTime > 5000 || processingEvents > 100) {
    return 'critical'
  }
  
  if (successRate < 98 || avgProcessingTime > 2000 || processingEvents > 50) {
    return 'warning'
  }
  
  return 'healthy'
}
```

### Webhook Dashboard Component

```typescript
// components/admin/WebhookDashboard.tsx
import { useState, useEffect } from 'react'
import { 
  ChartBarIcon, 
  ExclamationTriangleIcon, 
  CheckCircleIcon,
  ClockIcon
} from '@heroicons/react/24/outline'

export function WebhookDashboard() {
  const [metrics, setMetrics] = useState<any>(null)
  const [loading, setLoading] = useState(true)
  const [timeRange, setTimeRange] = useState('24h')

  useEffect(() => {
    loadMetrics()
  }, [timeRange])

  const loadMetrics = async () => {
    setLoading(true)
    try {
      const response = await fetch(`/api/admin/webhook-metrics?range=${timeRange}`)
      if (response.ok) {
        const data = await response.json()
        setMetrics(data)
      }
    } catch (error) {
      console.error('Failed to load webhook metrics:', error)
    } finally {
      setLoading(false)
    }
  }

  if (loading) {
    return <div className="animate-pulse bg-gray-200 rounded-lg h-96 w-full"></div>
  }

  if (!metrics) {
    return <div className="text-center py-8 text-gray-600">No webhook data available</div>
  }

  const getHealthStatusColor = () => {
    switch (metrics.healthStatus) {
      case 'healthy': return 'text-green-600'
      case 'warning': return 'text-yellow-600'
      case 'critical': return 'text-red-600'
      default: return 'text-gray-600'
    }
  }

  const getHealthStatusIcon = () => {
    switch (metrics.healthStatus) {
      case 'healthy': return <CheckCircleIcon className="h-5 w-5" />
      case 'warning': return <ExclamationTriangleIcon className="h-5 w-5" />
      case 'critical': return <ExclamationTriangleIcon className="h-5 w-5" />
      default: return <ClockIcon className="h-5 w-5" />
    }
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex justify-between items-center">
        <div>
          <h2 className="text-2xl font-bold text-gray-900">Webhook Monitoring</h2>
          <p className="text-gray-600">Real-time webhook health and performance metrics</p>
        </div>
        
        <div className="flex items-center space-x-4">
          {/* Health Status */}
          <div className={`flex items-center ${getHealthStatusColor()}`}>
            {getHealthStatusIcon()}
            <span className="ml-2 font-medium capitalize">{metrics.healthStatus}</span>
          </div>

          {/* Time Range Selector */}
          <select
            value={timeRange}
            onChange={(e) => setTimeRange(e.target.value)}
            className="border border-gray-300 rounded-md px-3 py-2"
          >
            <option value="1h">Last Hour</option>
            <option value="24h">Last 24 Hours</option>
            <option value="7d">Last 7 Days</option>
            <option value="30d">Last 30 Days</option>
          </select>
        </div>
      </div>

      {/* Key Metrics Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-6">
        <MetricCard
          title="Total Events"
          value={metrics.summary.totalEvents.toLocaleString()}
          icon={<ChartBarIcon className="h-6 w-6" />}
          color="blue"
        />
        
        <MetricCard
          title="Success Rate"
          value={`${metrics.summary.successRate.toFixed(1)}%`}
          icon={<CheckCircleIcon className="h-6 w-6" />}
          color={metrics.summary.successRate >= 98 ? "green" : "red"}
        />
        
        <MetricCard
          title="Avg Processing Time"
          value={`${metrics.performance.avgProcessingTime.toFixed(0)}ms`}
          icon={<ClockIcon className="h-6 w-6" />}
          color={metrics.performance.avgProcessingTime < 1000 ? "green" : "yellow"}
        />
        
        <MetricCard
          title="Failed Events"
          value={metrics.summary.failedEvents.toLocaleString()}
          icon={<ExclamationTriangleIcon className="h-6 w-6" />}
          color={metrics.summary.failedEvents === 0 ? "green" : "red"}
        />
      </div>

      {/* Timeline Chart */}
      <div className="bg-white rounded-lg border border-gray-200 p-6">
        <h3 className="text-lg font-medium text-gray-900 mb-4">Event Timeline</h3>
        <WebhookTimelineChart data={metrics.timeline} />
      </div>

      {/* Event Type Breakdown */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <div className="bg-white rounded-lg border border-gray-200 p-6">
          <h3 className="text-lg font-medium text-gray-900 mb-4">Event Types</h3>
          <EventTypeBreakdown data={metrics.breakdown.eventTypes} />
        </div>

        <div className="bg-white rounded-lg border border-gray-200 p-6">
          <h3 className="text-lg font-medium text-gray-900 mb-4">Error Breakdown</h3>
          <ErrorBreakdown data={metrics.breakdown.errors} />
        </div>
      </div>

      {/* Recent Failed Events */}
      <div className="bg-white rounded-lg border border-gray-200 p-6">
        <h3 className="text-lg font-medium text-gray-900 mb-4">Recent Failed Events</h3>
        <RecentFailedEvents />
      </div>
    </div>
  )
}

function MetricCard({ title, value, icon, color }: {
  title: string
  value: string
  icon: React.ReactNode
  color: string
}) {
  const colorClasses = {
    blue: 'text-blue-600 bg-blue-50',
    green: 'text-green-600 bg-green-50',
    yellow: 'text-yellow-600 bg-yellow-50',
    red: 'text-red-600 bg-red-50'
  }

  return (
    <div className="bg-white rounded-lg border border-gray-200 p-6">
      <div className="flex items-center">
        <div className={`p-2 rounded-lg ${colorClasses[color as keyof typeof colorClasses]}`}>
          {icon}
        </div>
        <div className="ml-4">
          <p className="text-sm font-medium text-gray-600">{title}</p>
          <p className="text-2xl font-bold text-gray-900">{value}</p>
        </div>
      </div>
    </div>
  )
}
```

## Debugging Tools

### Webhook Event Inspector

```typescript
// lib/webhook-debugger.ts
export class WebhookDebugger {
  private readonly supabase = createServerServiceRoleClient()

  /**
   * Get detailed information about a specific webhook event
   */
  public async inspectEvent(eventId: string): Promise<{
    event?: any
    logs?: any[]
    processing?: any
    relatedEvents?: any[]
    debugInfo?: any
  }> {
    
    try {
      // Get event logs
      const { data: logs } = await this.supabase
        .from('webhook_logs')
        .select('*')
        .eq('stripe_event_id', eventId)
        .order('created_at', { ascending: true })

      // Get processing details
      const { data: processing } = await this.supabase
        .from('webhook_events')
        .select('*')
        .eq('stripe_event_id', eventId)
        .single()

      // Get related events (same subscription)
      let relatedEvents: any[] = []
      if (processing?.subscription_id) {
        const { data: related } = await this.supabase
          .from('webhook_logs')
          .select('*')
          .eq('subscription_id', processing.subscription_id)
          .neq('stripe_event_id', eventId)
          .order('created_at', { ascending: false })
          .limit(10)

        relatedEvents = related || []
      }

      // Get debug information
      const debugInfo = await this.generateDebugInfo(eventId, logs, processing)

      return {
        event: processing,
        logs: logs || [],
        processing,
        relatedEvents,
        debugInfo
      }

    } catch (error) {
      console.error('❌ Event inspection failed:', error)
      throw error
    }
  }

  /**
   * Generate debug information for troubleshooting
   */
  private async generateDebugInfo(
    eventId: string,
    logs: any[],
    processing: any
  ): Promise<any> {
    
    const debugInfo: any = {
      eventId,
      timestamp: new Date().toISOString(),
      analysis: []
    }

    // Analyze processing time
    if (processing?.processing_time_ms) {
      if (processing.processing_time_ms > 5000) {
        debugInfo.analysis.push({
          type: 'performance',
          severity: 'warning',
          message: `Slow processing: ${processing.processing_time_ms}ms (threshold: 5000ms)`
        })
      }
    }

    // Analyze retry patterns
    const retryLogs = logs.filter(log => log.request_id !== logs[0]?.request_id)
    if (retryLogs.length > 0) {
      debugInfo.analysis.push({
        type: 'reliability',
        severity: 'info',
        message: `Event was retried ${retryLogs.length} times`
      })
    }

    // Analyze error patterns
    const errorLogs = logs.filter(log => log.status === 'failed')
    if (errorLogs.length > 0) {
      const errorMessages = errorLogs.map(log => log.error_message).filter(Boolean)
      const uniqueErrors = [...new Set(errorMessages)]
      
      debugInfo.analysis.push({
        type: 'error',
        severity: 'error',
        message: `Failed with ${uniqueErrors.length} unique error(s)`,
        details: uniqueErrors
      })
    }

    // Check for related subscription issues
    if (processing?.subscription_id) {
      const { data: subscription } = await this.supabase
        .from('subscriptions')
        .select('status, cancel_at_period_end, metadata')
        .eq('stripe_subscription_id', processing.subscription_id)
        .single()

      if (subscription) {
        debugInfo.subscriptionContext = {
          status: subscription.status,
          cancelAtPeriodEnd: subscription.cancel_at_period_end,
          hasScheduledChange: !!(subscription.metadata as any)?.scheduled_change
        }
      }
    }

    return debugInfo
  }

  /**
   * Test webhook handler with mock data
   */
  public async testHandler(
    eventType: string,
    mockData: any
  ): Promise<{ success: boolean; result?: any; error?: string; logs?: string[] }> {
    
    const logs: string[] = []
    const originalConsoleLog = console.log
    const originalConsoleError = console.error

    // Capture logs
    console.log = (...args) => {
      logs.push(`LOG: ${args.join(' ')}`)
      originalConsoleLog(...args)
    }

    console.error = (...args) => {
      logs.push(`ERROR: ${args.join(' ')}`)
      originalConsoleError(...args)
    }

    try {
      let result: any

      // Route to appropriate handler
      switch (eventType) {
        case 'invoice.payment_succeeded':
          const { handleInvoicePaymentPaid } = await import('@/app/api/webhooks/stripe/handlers')
          result = await handleInvoicePaymentPaid(mockData)
          break

        case 'subscription_schedule.updated':
          const { handleSubscriptionScheduleUpdated } = await import('@/app/api/webhooks/stripe/handlers')
          result = await handleSubscriptionScheduleUpdated(mockData)
          break

        default:
          throw new Error(`Unsupported event type for testing: ${eventType}`)
      }

      return { success: true, result, logs }

    } catch (error) {
      return { 
        success: false, 
        error: error instanceof Error ? error.message : 'Test failed',
        logs 
      }
    } finally {
      // Restore console
      console.log = originalConsoleLog
      console.error = originalConsoleError
    }
  }
}
```

## Alerting and Incident Response

### Webhook Alerting System

```typescript
// lib/webhook-alerting.ts
export class WebhookAlertingSystem {
  private readonly alertThresholds = {
    failureRate: 5, // 5%
    avgProcessingTime: 3000, // 3 seconds
    consecutiveFailures: 10,
    queueBacklog: 50
  }

  /**
   * Check metrics against thresholds and send alerts
   */
  public async checkAndAlert(): Promise<void> {
    try {
      const metrics = await getWebhookMetrics('1h') // Last hour
      const alerts = this.analyzeMetrics(metrics)

      for (const alert of alerts) {
        await this.sendAlert(alert)
      }

      if (alerts.length > 0) {
        console.log(`🚨 Sent ${alerts.length} webhook alerts`)
      }

    } catch (error) {
      console.error('❌ Webhook alerting check failed:', error)
    }
  }

  private analyzeMetrics(metrics: any): Array<{
    type: string
    severity: 'warning' | 'critical'
    message: string
    value: number
    threshold: number
  }> {
    
    const alerts = []

    // Check failure rate
    if (metrics.summary.failureRate > this.alertThresholds.failureRate) {
      alerts.push({
        type: 'failure_rate',
        severity: metrics.summary.failureRate > 10 ? 'critical' : 'warning',
        message: `High webhook failure rate: ${metrics.summary.failureRate.toFixed(1)}%`,
        value: metrics.summary.failureRate,
        threshold: this.alertThresholds.failureRate
      })
    }

    // Check processing time
    if (metrics.performance.avgProcessingTime > this.alertThresholds.avgProcessingTime) {
      alerts.push({
        type: 'slow_processing',
        severity: metrics.performance.avgProcessingTime > 10000 ? 'critical' : 'warning',
        message: `Slow webhook processing: ${metrics.performance.avgProcessingTime.toFixed(0)}ms average`,
        value: metrics.performance.avgProcessingTime,
        threshold: this.alertThresholds.avgProcessingTime
      })
    }

    // Check for stuck processing events
    if (metrics.summary.processingEvents > this.alertThresholds.queueBacklog) {
      alerts.push({
        type: 'queue_backlog',
        severity: 'critical',
        message: `Webhook queue backlog: ${metrics.summary.processingEvents} events stuck`,
        value: metrics.summary.processingEvents,
        threshold: this.alertThresholds.queueBacklog
      })
    }

    return alerts
  }

  private async sendAlert(alert: any): Promise<void> {
    try {
      // Send to monitoring service
      await monitoringService.alert({
        title: `Webhook ${alert.type.replace('_', ' ')} Alert`,
        description: alert.message,
        severity: alert.severity,
        context: {
          alertType: alert.type,
          currentValue: alert.value,
          threshold: alert.threshold,
          timestamp: new Date().toISOString()
        }
      })

      // Send email for critical alerts
      if (alert.severity === 'critical') {
        await emailService.send({
          to: process.env.ALERT_EMAIL!,
          template: 'webhook_critical_alert',
          data: {
            alertType: alert.type,
            message: alert.message,
            value: alert.value,
            threshold: alert.threshold,
            dashboardUrl: `${process.env.APP_URL}/admin/webhooks`
          }
        })
      }

    } catch (error) {
      console.error('❌ Failed to send webhook alert:', error)
    }
  }
}
```

### Incident Response Runbook

```typescript
// lib/webhook-incident-response.ts
export class WebhookIncidentResponse {
  /**
   * Automated incident response for webhook failures
   */
  public async respondToIncident(
    incidentType: 'high_failure_rate' | 'queue_backlog' | 'processing_timeout',
    severity: 'warning' | 'critical'
  ): Promise<{ actions: string[]; success: boolean }> {
    
    const actions: string[] = []

    try {
      switch (incidentType) {
        case 'high_failure_rate':
          await this.handleHighFailureRate(actions)
          break

        case 'queue_backlog':
          await this.handleQueueBacklog(actions)
          break

        case 'processing_timeout':
          await this.handleProcessingTimeout(actions)
          break
      }

      // Log incident response
      await this.logIncidentResponse(incidentType, severity, actions)

      return { actions, success: true }

    } catch (error) {
      console.error('❌ Incident response failed:', error)
      actions.push(`Incident response failed: ${error}`)
      return { actions, success: false }
    }
  }

  private async handleHighFailureRate(actions: string[]): Promise<void> {
    // Check database connectivity
    try {
      await testSupabase.from('subscriptions').select('id').limit(1)
      actions.push('Database connectivity: OK')
    } catch (error) {
      actions.push('Database connectivity: FAILED')
      
      // Attempt database reconnection
      await this.attemptDatabaseReconnection()
      actions.push('Attempted database reconnection')
    }

    // Check for common error patterns
    const recentErrors = await this.getRecentErrors()
    const errorPatterns = this.analyzeErrorPatterns(recentErrors)
    
    actions.push(`Analyzed ${recentErrors.length} recent errors`)
    actions.push(`Found ${errorPatterns.length} error patterns`)

    // Auto-fix common issues
    for (const pattern of errorPatterns) {
      if (pattern.autoFixable) {
        await this.applyAutoFix(pattern)
        actions.push(`Applied auto-fix for: ${pattern.type}`)
      }
    }
  }

  private async handleQueueBacklog(actions: string[]): Promise<void> {
    // Get stuck events
    const { data: stuckEvents } = await this.supabase
      .from('webhook_events')
      .select('*')
      .eq('status', 'processing')
      .lt('started_at', new Date(Date.now() - 10 * 60 * 1000).toISOString()) // 10+ minutes old

    actions.push(`Found ${stuckEvents?.length || 0} stuck events`)

    // Reset stuck events for retry
    if (stuckEvents && stuckEvents.length > 0) {
      await this.supabase
        .from('webhook_events')
        .update({
          status: 'pending',
          retry_count: this.supabase.raw('COALESCE(retry_count, 0) + 1'),
          reset_at: new Date().toISOString()
        })
        .in('id', stuckEvents.map(e => e.id))

      actions.push(`Reset ${stuckEvents.length} stuck events for retry`)
    }
  }

  private async handleProcessingTimeout(actions: string[]): Promise<void> {
    // Increase processing timeout temporarily
    await this.adjustProcessingTimeout(30000) // 30 seconds
    actions.push('Increased processing timeout to 30 seconds')

    // Scale processing workers if using queue system
    await this.scaleProcessingWorkers(2) // Double workers
    actions.push('Scaled processing workers')
  }

  private async logIncidentResponse(
    incidentType: string,
    severity: string,
    actions: string[]
  ): Promise<void> {
    
    await this.supabase
      .from('webhook_incidents')
      .insert({
        incident_type: incidentType,
        severity: severity,
        actions_taken: actions,
        resolved_at: new Date().toISOString(),
        created_at: new Date().toISOString()
      })
  }
}
```

## Testing Webhook Monitoring

### Monitoring Tests

```typescript
// __tests__/monitoring/webhook-monitoring.test.ts
import { WebhookHealthMonitor, WebhookAlertingSystem } from '@/lib/webhook-monitoring'

describe('Webhook Monitoring', () => {
  let healthMonitor: WebhookHealthMonitor
  let alertingSystem: WebhookAlertingSystem

  beforeAll(() => {
    healthMonitor = new WebhookHealthMonitor()
    alertingSystem = new WebhookAlertingSystem()
  })

  describe('Health Monitoring', () => {
    it('should detect healthy webhook system', async () => {
      // Seed with successful events
      await seedSuccessfulWebhookEvents(50)

      const health = await healthMonitor.checkWebhookHealth()

      expect(health.healthy).toBe(true)
      expect(health.alerts).toHaveLength(0)
      expect(health.metrics.failureRate).toBeLessThan(5)
    })

    it('should detect unhealthy webhook system', async () => {
      // Seed with failed events
      await seedFailedWebhookEvents(20)

      const health = await healthMonitor.checkWebhookHealth()

      expect(health.healthy).toBe(false)
      expect(health.alerts.length).toBeGreaterThan(0)
      expect(health.metrics.failureRate).toBeGreaterThan(10)
    })
  })

  describe('Alerting System', () => {
    it('should send alerts for high failure rates', async () => {
      const mockAlert = jest.fn()
      jest.spyOn(monitoringService, 'alert').mockImplementation(mockAlert)

      // Simulate high failure rate
      await seedFailedWebhookEvents(30)

      await alertingSystem.checkAndAlert()

      expect(mockAlert).toHaveBeenCalledWith(
        expect.objectContaining({
          title: expect.stringContaining('failure rate'),
          severity: expect.any(String)
        })
      )
    })
  })
})

async function seedSuccessfulWebhookEvents(count: number): Promise<void> {
  const events = []
  
  for (let i = 0; i < count; i++) {
    events.push({
      stripe_event_id: `evt_success_${i}`,
      event_type: 'invoice.payment_succeeded',
      status: 'completed',
      processing_time_ms: 100 + Math.random() * 500, // 100-600ms
      created_at: new Date(Date.now() - Math.random() * 60 * 60 * 1000).toISOString()
    })
  }

  await testSupabase.from('webhook_logs').insert(events)
}

async function seedFailedWebhookEvents(count: number): Promise<void> {
  const events = []
  
  for (let i = 0; i < count; i++) {
    events.push({
      stripe_event_id: `evt_failed_${i}`,
      event_type: 'customer.subscription.updated',
      status: 'failed',
      error_message: 'Database connection timeout',
      processing_time_ms: 5000 + Math.random() * 5000, // 5-10 seconds
      created_at: new Date(Date.now() - Math.random() * 60 * 60 * 1000).toISOString()
    })
  }

  await testSupabase.from('webhook_logs').insert(events)
}
```

## Next Steps

In the next module, we'll continue with test data management strategies for managing test customers and subscriptions.

## Key Takeaways

- Implement comprehensive webhook logging for all events and outcomes
- Monitor key metrics including success rate, processing time, and queue depth
- Set up automated alerting for webhook health degradation
- Build debugging tools for investigating webhook failures
- Implement incident response automation for common issues
- Test monitoring and alerting systems thoroughly
- Use real-time dashboards for operational visibility
- Track webhook performance trends over time
- Implement automated recovery for common failure patterns
- Maintain detailed logs for troubleshooting and audit purposes
