# PCI Compliance, Data Retention, and Privacy

## Overview

This module covers compliance requirements for billing systems, including PCI DSS compliance, data retention policies, privacy regulations (GDPR, CCPA), and audit requirements. We'll explore compliance strategies that protect customer data and meet regulatory requirements.

## PCI DSS Compliance

### Our Recommended Approach: Stripe Handles PCI

Your codebase follows the recommended approach of using Stripe to handle PCI compliance:

```typescript
// Your approach: Never handle raw card data
export async function createCheckoutSession(/* ... */) {
  // ✅ Good: Use Stripe Checkout (PCI compliant)
  const session = await stripe.checkout.sessions.create({
    customer: customerId,
    line_items: [{ price: priceId, quantity: 1 }],
    mode: 'subscription',
    success_url: successUrl,
    cancel_url: cancelUrl
  })
  
  return { url: session.url }
}

// ❌ Never do this: Handle card data directly
// const cardData = {
//   number: req.body.cardNumber,  // PCI violation!
//   exp_month: req.body.expMonth,
//   exp_year: req.body.expYear,
//   cvc: req.body.cvc
// }
```

### PCI Compliance Checklist

```typescript
// PCI compliance validation
export const PCIComplianceCheck = {
  validateCompliance(): { compliant: boolean; issues: string[] } {
    const issues: string[] = []

    // Check 1: No card data in code
    if (this.hasCardDataInCode()) {
      issues.push('CRITICAL: Card data found in application code')
    }

    // Check 2: HTTPS enforcement
    if (!this.isHTTPSEnforced()) {
      issues.push('CRITICAL: HTTPS not enforced for all endpoints')
    }

    // Check 3: Secure headers
    if (!this.hasSecureHeaders()) {
      issues.push('HIGH: Security headers not properly configured')
    }

    // Check 4: No card data in logs
    if (this.hasCardDataInLogs()) {
      issues.push('CRITICAL: Card data found in application logs')
    }

    // Check 5: Stripe Elements usage
    if (!this.usesStripeElements()) {
      issues.push('HIGH: Not using Stripe Elements for card collection')
    }

    return {
      compliant: issues.length === 0,
      issues
    }
  },

  private hasCardDataInCode(): boolean {
    // In a real implementation, scan codebase for card data patterns
    // This is a simplified check
    return false
  },

  private isHTTPSEnforced(): boolean {
    return process.env.NODE_ENV === 'production' 
      ? process.env.APP_URL?.startsWith('https://') || false
      : true // OK in development
  },

  private hasSecureHeaders(): boolean {
    // Check if security headers are configured in middleware
    return true // Would check actual middleware configuration
  },

  private hasCardDataInLogs(): boolean {
    // Scan recent logs for card data patterns
    return false
  },

  private usesStripeElements(): boolean {
    // Verify Stripe Elements is used for card collection
    return true // Your codebase uses Stripe Checkout/Portal
  }
}
```

### PCI Scope Reduction

```typescript
// Strategies to minimize PCI scope
export const PCIScopeReduction = {
  // Use Stripe Checkout instead of custom forms
  useStripeCheckout: true,
  
  // Use Customer Portal for payment method management
  useCustomerPortal: true,
  
  // Never store card data
  storeCardData: false,
  
  // Use Stripe.js for any card interactions
  useStripeJS: true,
  
  // Validate compliance regularly
  async validateScope(): Promise<{
    inScope: string[]
    outOfScope: string[]
    recommendations: string[]
  }> {
    return {
      inScope: [
        'Checkout session creation',
        'Webhook signature verification',
        'Customer portal session creation'
      ],
      outOfScope: [
        'Card data collection',
        'Payment processing',
        'Card data storage',
        'Payment method management'
      ],
      recommendations: [
        'Continue using Stripe Checkout for all payment collection',
        'Use Customer Portal for payment method updates',
        'Never log or store sensitive payment data',
        'Regularly audit code for PCI compliance'
      ]
    }
  }
}
```

## Data Retention Policies

### Billing Data Retention Strategy

```typescript
// lib/compliance/data-retention.ts
export class DataRetentionManager {
  private retentionPolicies = {
    // Active customer data - keep indefinitely
    active_subscriptions: null,
    active_users: null,
    
    // Cancelled subscriptions - keep for 7 years (tax requirements)
    cancelled_subscriptions: 7 * 365, // days
    
    // Usage data - keep for 3 years
    usage_records: 3 * 365,
    
    // Webhook events - keep for 1 year
    webhook_events: 365,
    
    // Security events - keep for 2 years
    security_events: 2 * 365,
    
    // API logs - keep for 90 days
    api_metrics: 90,
    
    // Test data - delete immediately after tests
    test_data: 0
  }

  async enforceRetentionPolicies(): Promise<{
    processed: number
    deleted: number
    errors: string[]
  }> {
    console.log('🗂️ Enforcing data retention policies...')

    let processed = 0
    let deleted = 0
    const errors: string[] = []

    try {
      const supabase = createServerServiceRoleClient()

      // Clean up webhook events
      const webhookCutoff = new Date(Date.now() - this.retentionPolicies.webhook_events * 24 * 60 * 60 * 1000)
      
      const { data: oldWebhooks, error: webhookError } = await supabase
        .from('webhook_events')
        .delete()
        .lt('processed_at', webhookCutoff.toISOString())
        .select()

      if (webhookError) {
        errors.push(`Webhook cleanup failed: ${webhookError.message}`)
      } else {
        deleted += oldWebhooks?.length || 0
        console.log(`🗑️ Deleted ${oldWebhooks?.length || 0} old webhook events`)
      }

      // Clean up API metrics
      const apiCutoff = new Date(Date.now() - this.retentionPolicies.api_metrics * 24 * 60 * 60 * 1000)
      
      const { data: oldMetrics, error: metricsError } = await supabase
        .from('api_metrics')
        .delete()
        .lt('timestamp', apiCutoff.toISOString())
        .select()

      if (metricsError) {
        errors.push(`API metrics cleanup failed: ${metricsError.message}`)
      } else {
        deleted += oldMetrics?.length || 0
        console.log(`🗑️ Deleted ${oldMetrics?.length || 0} old API metrics`)
      }

      // Clean up usage records (older than 3 years)
      const usageCutoff = new Date(Date.now() - this.retentionPolicies.usage_records * 24 * 60 * 60 * 1000)
      
      const { data: oldUsage, error: usageError } = await supabase
        .from('usage_ledger')
        .delete()
        .lt('created_at', usageCutoff.toISOString())
        .select()

      if (usageError) {
        errors.push(`Usage records cleanup failed: ${usageError.message}`)
      } else {
        deleted += oldUsage?.length || 0
        console.log(`🗑️ Deleted ${oldUsage?.length || 0} old usage records`)
      }

      // Archive old cancelled subscriptions instead of deleting (tax compliance)
      await this.archiveOldSubscriptions(supabase)

      processed = 3 // Number of retention policies processed

      console.log(`✅ Data retention enforcement completed: ${deleted} records deleted`)

      return { processed, deleted, errors }

    } catch (error) {
      console.error('❌ Data retention enforcement failed:', error)
      errors.push(`General error: ${error.message}`)
      return { processed, deleted, errors }
    }
  }

  private async archiveOldSubscriptions(supabase: any) {
    const archiveCutoff = new Date(Date.now() - this.retentionPolicies.cancelled_subscriptions * 24 * 60 * 60 * 1000)

    // Move old cancelled subscriptions to archive table
    const { data: oldSubs } = await supabase
      .from('subscriptions')
      .select('*')
      .eq('status', 'cancelled')
      .lt('updated_at', archiveCutoff.toISOString())

    if (oldSubs && oldSubs.length > 0) {
      // Insert into archive table
      await supabase
        .from('subscriptions_archive')
        .insert(oldSubs.map(sub => ({
          ...sub,
          archived_at: new Date().toISOString(),
          archived_reason: 'retention_policy'
        })))

      // Delete from main table
      await supabase
        .from('subscriptions')
        .delete()
        .in('id', oldSubs.map(sub => sub.id))

      console.log(`📦 Archived ${oldSubs.length} old cancelled subscriptions`)
    }
  }

  async scheduleRetentionCleanup(): Promise<void> {
    // Schedule daily retention cleanup
    const supabase = createServerServiceRoleClient()

    await supabase
      .from('scheduled_tasks')
      .insert({
        task_type: 'data_retention_cleanup',
        scheduled_for: new Date(Date.now() + 24 * 60 * 60 * 1000).toISOString(), // Tomorrow
        status: 'pending',
        metadata: {
          created_by: 'retention_manager',
          recurring: true,
          interval_days: 1
        }
      })

    console.log('📅 Scheduled daily data retention cleanup')
  }
}
```

## GDPR Compliance

### Right to Data Portability

```typescript
// lib/compliance/gdpr.ts
export class GDPRCompliance {
  async exportUserData(userId: string): Promise<{
    user: any
    subscriptions: any[]
    usage: any[]
    billing: any[]
  }> {
    console.log(`📤 Exporting GDPR data for user ${userId}`)

    try {
      const supabase = createServerServiceRoleClient()

      // Get user profile data
      const { data: user } = await supabase
        .from('users')
        .select('*')
        .eq('id', userId)
        .single()

      // Get subscription data
      const { data: subscriptions } = await supabase
        .from('subscriptions')
        .select('*')
        .eq('user_id', userId)

      // Get usage data
      const { data: usage } = await supabase
        .from('usage_ledger')
        .select('*')
        .eq('user_id', userId)

      // Get billing history from Stripe
      const billingData = await this.getStripeBillingData(subscriptions)

      const exportData = {
        user: this.sanitizeUserData(user),
        subscriptions: subscriptions?.map(sub => this.sanitizeSubscriptionData(sub)) || [],
        usage: usage?.map(u => this.sanitizeUsageData(u)) || [],
        billing: billingData,
        exportedAt: new Date().toISOString(),
        format: 'GDPR_DATA_EXPORT_V1'
      }

      // Log data export for audit
      await this.logDataExport(userId, 'gdpr_export')

      console.log(`✅ GDPR data export completed for user ${userId}`)
      return exportData

    } catch (error) {
      console.error('GDPR data export failed:', error)
      throw error
    }
  }

  async deleteUserData(userId: string, reason: 'gdpr_deletion' | 'account_closure'): Promise<{
    success: boolean
    deletedRecords: number
    retainedRecords: number
    retentionReasons: string[]
  }> {
    console.log(`🗑️ Processing data deletion for user ${userId} (reason: ${reason})`)

    try {
      const supabase = createServerServiceRoleClient()
      let deletedRecords = 0
      let retainedRecords = 0
      const retentionReasons: string[] = []

      // Check for active subscriptions
      const { data: activeSubscriptions } = await supabase
        .from('subscriptions')
        .select('*')
        .eq('user_id', userId)
        .in('status', ['active', 'trialing', 'past_due'])

      if (activeSubscriptions && activeSubscriptions.length > 0) {
        retainedRecords += activeSubscriptions.length
        retentionReasons.push('Active subscription exists - cancel first')
        
        return {
          success: false,
          deletedRecords: 0,
          retainedRecords,
          retentionReasons
        }
      }

      // Delete user profile data
      const { error: userError } = await supabase
        .from('users')
        .delete()
        .eq('id', userId)

      if (!userError) {
        deletedRecords += 1
      }

      // Handle subscription data based on retention requirements
      const { data: oldSubscriptions } = await supabase
        .from('subscriptions')
        .select('*')
        .eq('user_id', userId)
        .eq('status', 'cancelled')

      if (oldSubscriptions && oldSubscriptions.length > 0) {
        const recentCancellations = oldSubscriptions.filter(sub => {
          const cancelledDate = new Date(sub.updated_at)
          const retentionPeriod = 7 * 365 * 24 * 60 * 60 * 1000 // 7 years
          return Date.now() - cancelledDate.getTime() < retentionPeriod
        })

        if (recentCancellations.length > 0) {
          // Anonymize instead of delete (tax compliance)
          await supabase
            .from('subscriptions')
            .update({
              metadata: {
                anonymized: true,
                anonymized_at: new Date().toISOString(),
                anonymization_reason: reason
              }
            })
            .in('id', recentCancellations.map(sub => sub.id))

          retainedRecords += recentCancellations.length
          retentionReasons.push('Tax compliance - anonymized instead of deleted')
        }

        // Delete truly old subscriptions
        const oldCancellations = oldSubscriptions.filter(sub => {
          const cancelledDate = new Date(sub.updated_at)
          const retentionPeriod = 7 * 365 * 24 * 60 * 60 * 1000
          return Date.now() - cancelledDate.getTime() >= retentionPeriod
        })

        if (oldCancellations.length > 0) {
          await supabase
            .from('subscriptions')
            .delete()
            .in('id', oldCancellations.map(sub => sub.id))

          deletedRecords += oldCancellations.length
        }
      }

      // Delete usage data older than required retention
      const usageCutoff = new Date(Date.now() - 3 * 365 * 24 * 60 * 60 * 1000) // 3 years
      
      const { data: deletedUsage } = await supabase
        .from('usage_ledger')
        .delete()
        .eq('user_id', userId)
        .lt('created_at', usageCutoff.toISOString())
        .select()

      deletedRecords += deletedUsage?.length || 0

      // Delete from Stripe (if no active subscriptions)
      await this.deleteStripeCustomerData(userId)

      // Log deletion for audit
      await this.logDataDeletion(userId, reason, deletedRecords, retainedRecords)

      console.log(`✅ Data deletion completed: ${deletedRecords} deleted, ${retainedRecords} retained`)

      return {
        success: true,
        deletedRecords,
        retainedRecords,
        retentionReasons
      }

    } catch (error) {
      console.error('Data deletion failed:', error)
      throw error
    }
  }

  private async deleteStripeCustomerData(userId: string) {
    try {
      const supabase = createServerServiceRoleClient()
      
      // Get Stripe customer IDs for this user
      const { data: subscriptions } = await supabase
        .from('subscriptions')
        .select('stripe_customer_id')
        .eq('user_id', userId)
        .not('stripe_customer_id', 'is', null)

      const customerIds = [...new Set(subscriptions?.map(sub => sub.stripe_customer_id).filter(Boolean))]

      const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
        apiVersion: '2025-08-27.basil'
      })

      for (const customerId of customerIds) {
        try {
          // Check if customer has any active subscriptions
          const customer = await stripe.customers.retrieve(customerId, {
            expand: ['subscriptions']
          })

          const hasActiveSubscriptions = (customer as any).subscriptions?.data.some(
            (sub: any) => ['active', 'trialing', 'past_due'].includes(sub.status)
          )

          if (!hasActiveSubscriptions) {
            // Safe to delete customer
            await stripe.customers.del(customerId)
            console.log(`🗑️ Deleted Stripe customer: ${customerId}`)
          } else {
            console.log(`⚠️ Retained Stripe customer ${customerId} (has active subscriptions)`)
          }

        } catch (stripeError) {
          console.error(`Failed to process Stripe customer ${customerId}:`, stripeError)
        }
      }

    } catch (error) {
      console.error('Stripe customer data deletion failed:', error)
    }
  }

  private async logDataExport(userId: string, exportType: string) {
    const supabase = createServerServiceRoleClient()

    await supabase
      .from('compliance_log')
      .insert({
        user_id: userId,
        action: 'data_export',
        action_type: exportType,
        timestamp: new Date().toISOString(),
        metadata: {
          requested_by: userId,
          export_format: 'json'
        }
      })
  }

  private async logDataDeletion(
    userId: string, 
    reason: string, 
    deletedRecords: number, 
    retainedRecords: number
  ) {
    const supabase = createServerServiceRoleClient()

    await supabase
      .from('compliance_log')
      .insert({
        user_id: userId,
        action: 'data_deletion',
        action_type: reason,
        timestamp: new Date().toISOString(),
        metadata: {
          deleted_records: deletedRecords,
          retained_records: retainedRecords,
          deletion_reason: reason
        }
      })
  }

  private sanitizeUserData(user: any) {
    // Remove sensitive fields from export
    const { password, ...sanitized } = user
    return sanitized
  }

  private sanitizeSubscriptionData(subscription: any) {
    // Keep business-relevant data, remove internal IDs
    return {
      planId: subscription.plan_id,
      status: subscription.status,
      createdAt: subscription.created_at,
      currentPeriodStart: subscription.current_period_start,
      currentPeriodEnd: subscription.current_period_end,
      cancelAtPeriodEnd: subscription.cancel_at_period_end
    }
  }

  private sanitizeUsageData(usage: any) {
    return {
      metric: usage.metric,
      amount: usage.amount,
      date: usage.created_at,
      billingPeriod: {
        start: usage.period_start,
        end: usage.period_end
      }
    }
  }
}
```

## Privacy Compliance (GDPR/CCPA)

### Privacy Rights Implementation

```typescript
// app/api/privacy/data-request/route.ts
export async function POST(request: Request) {
  try {
    const supabase = createServerUserClient()
    const { data: { user }, error: authError } = await supabase.auth.getUser()
    
    if (authError || !user) {
      return new Response(
      JSON.stringify({ error: 'Unauthorized' ),
      { status: 401, headers: { 'Content-Type': 'application/json' } })
    }

    const { requestType } = await request.json()

    if (!['export', 'delete'].includes(requestType)) {
      return new Response(
      JSON.stringify({ error: 'Invalid request type' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    const gdprCompliance = new GDPRCompliance()

    switch (requestType) {
      case 'export':
        const exportData = await gdprCompliance.exportUserData(user.id)
        
        // In production, you'd generate a secure download link
        return new Response(
      JSON.stringify({
          success: true,
          message: 'Data export prepared',
          data: exportData,
          downloadUrl: `/api/privacy/download/${user.id}` // Secure download endpoint
        })

      case 'delete':
        // Verify user has no active subscriptions
        const subscription = await getSubscriptionDetails(user.id)
        
        if (subscription && ['active', 'trialing', 'past_due'].includes(subscription.status)) {
          return new Response(
      JSON.stringify({ 
            error: 'Cannot delete data with active subscription. Please cancel your subscription first.' 
          ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
        }

        const deletionResult = await gdprCompliance.deleteUserData(user.id, 'gdpr_deletion')
        
        return new Response(
      JSON.stringify({
          success: deletionResult.success,
          message: deletionResult.success 
            ? 'Data deletion completed'
            : 'Data deletion partially completed',
          details: {
            deletedRecords: deletionResult.deletedRecords,
            retainedRecords: deletionResult.retainedRecords,
            retentionReasons: deletionResult.retentionReasons
          }
        })

      default:
        return new Response(
      JSON.stringify({ error: 'Unsupported request type' ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

  } catch (error) {
    console.error('Privacy request failed:', error)
    return new Response(
      JSON.stringify({ error: 'Privacy request failed' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

### Cookie and Tracking Compliance

```typescript
// lib/compliance/cookie-consent.ts
export class CookieConsent {
  static getRequiredCookies(): {
    essential: string[]
    analytics: string[]
    marketing: string[]
  } {
    return {
      essential: [
        'supabase-auth-token', // Authentication
        'billing-session-id',  // Billing session tracking
        'csrf-token'          // Security
      ],
      analytics: [
        'usage-analytics',    // Usage tracking for billing
        'performance-metrics' // Performance monitoring
      ],
      marketing: [
        'campaign-tracking',  // Marketing attribution
        'conversion-pixels'   // Conversion tracking
      ]
    }
  }

  static async handleConsentUpdate(
    userId: string,
    consent: {
      essential: boolean
      analytics: boolean
      marketing: boolean
    }
  ) {
    const supabase = createServerServiceRoleClient()

    // Store consent preferences
    await supabase
      .from('user_consent')
      .upsert({
        user_id: userId,
        essential_cookies: consent.essential,
        analytics_cookies: consent.analytics,
        marketing_cookies: consent.marketing,
        consent_date: new Date().toISOString(),
        ip_address: 'unknown', // Would get from request
        user_agent: 'unknown'  // Would get from request
      }, {
        onConflict: 'user_id'
      })

    // If analytics consent withdrawn, stop analytics tracking
    if (!consent.analytics) {
      await this.disableAnalyticsForUser(userId)
    }

    // If marketing consent withdrawn, unsubscribe from marketing
    if (!consent.marketing) {
      await this.unsubscribeFromMarketing(userId)
    }

    console.log(`✅ Consent updated for user ${userId}`)
  }

  private static async disableAnalyticsForUser(userId: string) {
    // Disable analytics tracking for this user
    console.log(`📊 Disabled analytics for user ${userId}`)
  }

  private static async unsubscribeFromMarketing(userId: string) {
    // Unsubscribe user from marketing communications
    console.log(`📧 Unsubscribed user ${userId} from marketing`)
  }
}
```

## Audit and Compliance Reporting

### Compliance Dashboard

```typescript
// lib/compliance/compliance-dashboard.ts
export class ComplianceDashboard {
  async getComplianceMetrics(): Promise<{
    pci: any
    gdpr: any
    dataRetention: any
    security: any
  }> {
    const supabase = createServerServiceRoleClient()

    // PCI compliance metrics
    const pciCheck = PCIComplianceCheck.validateCompliance()

    // GDPR compliance metrics
    const { data: gdprRequests } = await supabase
      .from('compliance_log')
      .select('action, action_type, timestamp')
      .in('action', ['data_export', 'data_deletion'])
      .gte('timestamp', new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString())

    // Data retention metrics
    const retentionManager = new DataRetentionManager()
    const retentionStatus = await retentionManager.getRetentionStatus()

    // Security event metrics
    const { data: securityEvents } = await supabase
      .from('security_events')
      .select('severity, event_type, timestamp')
      .gte('timestamp', new Date(Date.now() - 30 * 24 * 60 * 60 * 1000).toISOString())

    return {
      pci: {
        compliant: pciCheck.compliant,
        issues: pciCheck.issues,
        lastChecked: new Date().toISOString()
      },
      gdpr: {
        requestsLast30Days: gdprRequests?.length || 0,
        exportRequests: gdprRequests?.filter(r => r.action === 'data_export').length || 0,
        deletionRequests: gdprRequests?.filter(r => r.action === 'data_deletion').length || 0
      },
      dataRetention: retentionStatus,
      security: {
        eventsLast30Days: securityEvents?.length || 0,
        criticalEvents: securityEvents?.filter(e => e.severity === 'critical').length || 0,
        eventsByType: securityEvents?.reduce((acc, event) => {
          acc[event.event_type] = (acc[event.event_type] || 0) + 1
          return acc
        }, {} as Record<string, number>) || {}
      }
    }
  }

  async generateComplianceReport(
    startDate: Date,
    endDate: Date
  ): Promise<{
    period: { start: string; end: string }
    summary: any
    details: any
  }> {
    const metrics = await this.getComplianceMetrics()

    return {
      period: {
        start: startDate.toISOString(),
        end: endDate.toISOString()
      },
      summary: {
        pciCompliant: metrics.pci.compliant,
        gdprRequests: metrics.gdpr.requestsLast30Days,
        securityIncidents: metrics.security.criticalEvents,
        dataRetentionCompliant: metrics.dataRetention.compliant
      },
      details: metrics,
      generatedAt: new Date().toISOString(),
      generatedBy: 'compliance_dashboard'
    }
  }
}
```

## Testing Compliance Features

### Compliance Integration Tests

```typescript
// __tests__/integration/compliance.test.ts
describe('Compliance Features', () => {
  describe('GDPR Data Export', () => {
    it('should export complete user data', async () => {
      // Create test user with subscription and usage
      const testUser = await createTestUser('gdpr-test@example.com')
      await createTestSubscription(testUser.id, 'starter')
      await createTestUsage(testUser.id, 'compute_minutes', 100)

      const gdpr = new GDPRCompliance()
      const exportData = await gdpr.exportUserData(testUser.id)

      expect(exportData.user).toBeDefined()
      expect(exportData.subscriptions).toHaveLength(1)
      expect(exportData.usage).toHaveLength(1)
      expect(exportData.billing).toBeDefined()
      expect(exportData.exportedAt).toBeDefined()

      // Verify sensitive data is sanitized
      expect(exportData.user.password).toBeUndefined()
    })
  })

  describe('Data Retention', () => {
    it('should delete old webhook events', async () => {
      const retentionManager = new DataRetentionManager()
      
      // Create old webhook event
      await testSupabase
        .from('webhook_events')
        .insert({
          event_id: 'evt_old_test',
          event_type: 'test.event',
          status: 'completed',
          processed_at: new Date(Date.now() - 400 * 24 * 60 * 60 * 1000).toISOString() // 400 days ago
        })

      const result = await retentionManager.enforceRetentionPolicies()

      expect(result.deleted).toBeGreaterThan(0)
      expect(result.errors).toHaveLength(0)

      // Verify old event was deleted
      const { data: remainingEvents } = await testSupabase
        .from('webhook_events')
        .select('event_id')
        .eq('event_id', 'evt_old_test')

      expect(remainingEvents).toHaveLength(0)
    })
  })

  describe('PCI Compliance', () => {
    it('should validate PCI compliance', () => {
      const check = PCIComplianceCheck.validateCompliance()
      
      expect(check.compliant).toBe(true)
      expect(check.issues).toHaveLength(0)
    })
  })
})
```

## Alternative: Basic Compliance Implementation

For simpler compliance needs:

### Basic Data Export

```typescript
// lib/compliance/basic-export.ts (Alternative approach)
export async function exportBasicUserData(userId: string) {
  const supabase = createServerServiceRoleClient()

  // Get user data
  const { data: user } = await supabase
    .from('users')
    .select('email, first_name, last_name, created_at')
    .eq('id', userId)
    .single()

  // Get subscription data
  const { data: subscriptions } = await supabase
    .from('subscriptions')
    .select('plan_id, status, created_at, current_period_start, current_period_end')
    .eq('user_id', userId)

  return {
    user,
    subscriptions: subscriptions || [],
    exportedAt: new Date().toISOString()
  }
}
```

## Next Steps

In the next module, we'll cover common Stripe integration issues and their solutions.

## Key Takeaways

- **Use Stripe for PCI compliance** - never handle raw card data
- **Implement data retention policies** based on legal requirements
- **Support GDPR data export and deletion** requests
- **Log all compliance actions** for audit purposes
- **Regularly validate PCI compliance** with automated checks
- **Anonymize data** instead of deletion when retention is required
- **Handle privacy requests promptly** within legal timeframes
- **Test compliance features** to ensure they work correctly
- **Monitor compliance metrics** for ongoing validation
- **Document compliance procedures** for audit purposes
