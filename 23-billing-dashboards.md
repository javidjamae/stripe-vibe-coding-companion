# Building Comprehensive Billing Dashboards

## Overview

This module covers building comprehensive billing dashboards that combine subscription information, usage tracking, billing history, and plan management. We'll explore how to create user-friendly interfaces that provide complete billing visibility.

## Dashboard Architecture

Your billing dashboard should provide a unified view of:

```
Subscription Status → Usage Tracking → Billing History → Plan Controls → Payment Methods
```

### Core Dashboard Components

1. **Current Plan Overview**: Active subscription and features
2. **Usage Metrics**: Current period consumption and limits
3. **Billing Information**: Next payment, history, and receipts
4. **Plan Management**: Upgrade/downgrade controls
5. **Account Settings**: Payment methods and preferences

## Main Billing Dashboard

### Primary Dashboard Component

```typescript
// app/(app)/billing/page.tsx
'use client'

import { useState, useEffect } from 'react'
import { useAuth } from '@/hooks/useAuth'
import { CurrentPlanSection } from '@/components/billing/CurrentPlanSection'
import { UsageSection } from '@/components/billing/UsageSection'
import { BillingHistorySection } from '@/components/billing/BillingHistorySection'
import { PlanManagementSection } from '@/components/billing/PlanManagementSection'
import { ScheduledChangeBanner } from '@/components/billing/ScheduledChangeBanner'
import { useSubscription } from '@/hooks/useSubscription'
import { useScheduledChange } from '@/hooks/useScheduledChange'

export default function BillingPage() {
  const { user } = useAuth()
  const { subscription, loading: subLoading, reload: reloadSubscription } = useSubscription()
  const { scheduledChange } = useScheduledChange()
  const [activeTab, setActiveTab] = useState<'overview' | 'usage' | 'history' | 'plans'>('overview')

  // Handle success/cancel URL parameters
  useEffect(() => {
    const urlParams = new URLSearchParams(window.location.search)
    const success = urlParams.get('success')
    const canceled = urlParams.get('canceled')

    if (success === 'true') {
      // Show success message and reload subscription data
      showSuccessToast('Subscription updated successfully!')
      reloadSubscription()
      
      // Clean URL
      window.history.replaceState({}, '', '/billing')
    }

    if (canceled === 'true') {
      showInfoToast('Checkout was canceled. No changes were made.')
      window.history.replaceState({}, '', '/billing')
    }
  }, [])

  if (!user) {
    return (
      <div className="max-w-4xl mx-auto p-6">
        <div className="text-center py-12">
          <h1 className="text-2xl font-bold text-gray-900">Billing Dashboard</h1>
          <p className="text-gray-600 mt-2">Please sign in to view your billing information.</p>
        </div>
      </div>
    )
  }

  return (
    <div className="max-w-6xl mx-auto p-6">
      <div className="mb-8">
        <h1 className="text-3xl font-bold text-gray-900">Billing Dashboard</h1>
        <p className="text-gray-600 mt-2">
          Manage your subscription, view usage, and update billing settings.
        </p>
      </div>

      {/* Scheduled Change Banner */}
      {scheduledChange.hasScheduledChange && (
        <div className="mb-6">
          <ScheduledChangeBanner />
        </div>
      )}

      {/* Tab Navigation */}
      <div className="border-b border-gray-200 mb-8">
        <nav className="-mb-px flex space-x-8">
          {[
            { id: 'overview', label: 'Overview', icon: '📊' },
            { id: 'usage', label: 'Usage', icon: '📈' },
            { id: 'history', label: 'Billing History', icon: '📄' },
            { id: 'plans', label: 'Change Plan', icon: '⚡' }
          ].map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id as any)}
              className={`py-3 px-1 border-b-2 font-medium text-sm flex items-center ${
                activeTab === tab.id
                  ? 'border-blue-500 text-blue-600'
                  : 'border-transparent text-gray-500 hover:text-gray-700 hover:border-gray-300'
              }`}
            >
              <span className="mr-2">{tab.icon}</span>
              {tab.label}
            </button>
          ))}
        </nav>
      </div>

      {/* Tab Content */}
      <div className="space-y-8">
        {activeTab === 'overview' && (
          <>
            <CurrentPlanSection 
              subscription={subscription} 
              loading={subLoading} 
            />
            <UsageSection 
              userId={user.id} 
              subscription={subscription} 
            />
          </>
        )}

        {activeTab === 'usage' && (
          <div className="space-y-6">
            <DetailedUsageSection userId={user.id} subscription={subscription} />
            <UsageHistorySection userId={user.id} />
          </div>
        )}

        {activeTab === 'history' && (
          <BillingHistorySection 
            customerId={subscription?.stripe_customer_id} 
          />
        )}

        {activeTab === 'plans' && (
          <PlanManagementSection 
            currentSubscription={subscription}
            onPlanChange={reloadSubscription}
          />
        )}
      </div>
    </div>
  )
}

function showSuccessToast(message: string) {
  // Implementation depends on your toast system
  console.log('✅', message)
}

function showInfoToast(message: string) {
  // Implementation depends on your toast system
  console.log('ℹ️', message)
}
```

### Current Plan Section

```typescript
// components/billing/CurrentPlanSection.tsx
import { CreditCardIcon, CalendarIcon, CheckCircleIcon } from '@heroicons/react/24/outline'
import { formatPlanPrice, getPlanConfig } from '@/lib/plan-config'
import { CustomerPortalButton } from './CustomerPortalButton'

interface CurrentPlanSectionProps {
  subscription: any
  loading: boolean
}

export function CurrentPlanSection({ subscription, loading }: CurrentPlanSectionProps) {
  if (loading) {
    return <div className="animate-pulse bg-gray-200 rounded-lg h-48 w-full"></div>
  }

  if (!subscription) {
    return (
      <div className="bg-white rounded-lg border border-gray-200 p-6">
        <h2 className="text-xl font-semibold mb-4">Current Plan</h2>
        <div className="text-center py-8">
          <p className="text-gray-600 mb-4">You're currently on the free plan.</p>
          <button
            onClick={() => window.location.href = '/pricing'}
            className="bg-blue-600 text-white px-6 py-2 rounded-md hover:bg-blue-700"
          >
            Upgrade to Paid Plan
          </button>
        </div>
      </div>
    )
  }

  const planConfig = getPlanConfig(subscription.plan_id)
  const billingInterval = getBillingIntervalFromPrice(subscription.stripe_price_id)
  const nextBillingDate = new Date(subscription.current_period_end)
  const daysUntilBilling = Math.ceil((nextBillingDate.getTime() - Date.now()) / (1000 * 60 * 60 * 24))

  // Check for scheduled changes
  const scheduledChange = (subscription.metadata as any)?.scheduled_change
  const hasScheduledChange = scheduledChange || subscription.cancel_at_period_end

  return (
    <div className="bg-white rounded-lg border border-gray-200 p-6">
      <div className="flex justify-between items-start mb-6">
        <div>
          <h2 className="text-xl font-semibold text-gray-900">Current Plan</h2>
          <p className="text-gray-600">Manage your subscription and billing</p>
        </div>
        <CustomerPortalButton variant="secondary" />
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* Plan Information */}
        <div className="lg:col-span-2">
          <div className="flex items-center mb-4">
            <div className="bg-blue-100 rounded-full p-2 mr-3">
              <CheckCircleIcon className="h-6 w-6 text-blue-600" />
            </div>
            <div>
              <h3 className="text-lg font-medium text-gray-900">
                {planConfig?.name || subscription.plan_id}
                {hasScheduledChange && (
                  <span className="ml-2 text-sm text-yellow-600">(Changing)</span>
                )}
              </h3>
              <p className="text-sm text-gray-600">
                {formatPlanPrice(subscription.plan_id, billingInterval)}
                {hasScheduledChange && scheduledChange && (
                  <span className="ml-2">
                    → {formatPlanPrice(scheduledChange.planId, scheduledChange.interval)} 
                    on {new Date(scheduledChange.effectiveAt).toLocaleDateString()}
                  </span>
                )}
              </p>
            </div>
          </div>

          {/* Plan Features */}
          <div className="space-y-2">
            <div className="flex justify-between text-sm">
              <span className="text-gray-600">Compute Minutes</span>
              <span className="font-medium">{planConfig?.includedComputeMinutes.toLocaleString()}/month</span>
            </div>
            <div className="flex justify-between text-sm">
              <span className="text-gray-600">Concurrent Jobs</span>
              <span className="font-medium">{planConfig?.concurrencyLimit}</span>
            </div>
            <div className="flex justify-between text-sm">
              <span className="text-gray-600">Overages</span>
              <span className="font-medium">
                {planConfig?.allowOverages ? 
                  `$${(planConfig.overagePricePerMinuteCents || 0) / 100}/min` : 
                  'Not available'
                }
              </span>
            </div>
          </div>
        </div>

        {/* Billing Information */}
        <div className="bg-gray-50 rounded-lg p-4">
          <div className="flex items-center mb-3">
            <CalendarIcon className="h-5 w-5 text-gray-400 mr-2" />
            <h4 className="font-medium text-gray-900">Billing Cycle</h4>
          </div>
          
          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-gray-600">Status</span>
              <span className={`font-medium capitalize ${
                subscription.status === 'active' ? 'text-green-600' : 'text-yellow-600'
              }`}>
                {subscription.status}
              </span>
            </div>
            
            <div className="flex justify-between">
              <span className="text-gray-600">Next billing</span>
              <span className="font-medium">
                {nextBillingDate.toLocaleDateString()}
              </span>
            </div>
            
            <div className="flex justify-between">
              <span className="text-gray-600">Days remaining</span>
              <span className="font-medium">{daysUntilBilling}</span>
            </div>
          </div>

          {/* Billing Progress Bar */}
          <div className="mt-4">
            <div className="w-full bg-gray-200 rounded-full h-2">
              <div 
                className="bg-blue-600 h-2 rounded-full transition-all"
                style={{ 
                  width: `${Math.max(0, Math.min(100, ((30 - daysUntilBilling) / 30) * 100))}%` 
                }}
              ></div>
            </div>
            <p className="text-xs text-gray-500 mt-1">Billing period progress</p>
          </div>
        </div>
      </div>
    </div>
  )
}
```

### Usage Dashboard Section

```typescript
// components/billing/UsageSection.tsx
import { useState, useEffect } from 'react'
import { ChartBarIcon, ExclamationTriangleIcon } from '@heroicons/react/24/outline'

interface UsageSectionProps {
  userId: string
  subscription: any
}

export function UsageSection({ userId, subscription }: UsageSectionProps) {
  const [usage, setUsage] = useState<any>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (userId && subscription) {
      loadUsageData()
    }
  }, [userId, subscription])

  const loadUsageData = async () => {
    setLoading(true)
    try {
      const response = await fetch(`/api/usage/summary?userId=${userId}`)
      if (response.ok) {
        const data = await response.json()
        setUsage(data)
      }
    } catch (error) {
      console.error('Failed to load usage data:', error)
    } finally {
      setLoading(false)
    }
  }

  if (loading) {
    return <div className="animate-pulse bg-gray-200 rounded-lg h-64 w-full"></div>
  }

  if (!subscription || !usage) {
    return (
      <div className="bg-white rounded-lg border border-gray-200 p-6">
        <h2 className="text-xl font-semibold mb-4">Usage This Month</h2>
        <p className="text-gray-600">No usage data available.</p>
      </div>
    )
  }

  const planConfig = getPlanConfig(subscription.plan_id)
  const computeUsage = usage.computeMinutes || 0
  const computeLimit = planConfig?.includedComputeMinutes || 0
  const usagePercent = computeLimit > 0 ? (computeUsage / computeLimit) * 100 : 0
  const isNearLimit = usagePercent >= 80
  const isOverLimit = usagePercent >= 100

  return (
    <div className="bg-white rounded-lg border border-gray-200 p-6">
      <div className="flex items-center justify-between mb-6">
        <div className="flex items-center">
          <ChartBarIcon className="h-6 w-6 text-gray-400 mr-2" />
          <h2 className="text-xl font-semibold text-gray-900">Usage This Month</h2>
        </div>
        <button
          onClick={loadUsageData}
          className="text-sm text-blue-600 hover:text-blue-700"
        >
          Refresh
        </button>
      </div>

      {/* Usage Alert */}
      {(isNearLimit || isOverLimit) && (
        <div className={`mb-6 p-4 rounded-lg border ${
          isOverLimit 
            ? 'bg-red-50 border-red-200' 
            : 'bg-yellow-50 border-yellow-200'
        }`}>
          <div className="flex items-start">
            <ExclamationTriangleIcon className={`h-5 w-5 mt-0.5 mr-3 ${
              isOverLimit ? 'text-red-400' : 'text-yellow-400'
            }`} />
            <div>
              <h4 className={`font-medium ${
                isOverLimit ? 'text-red-800' : 'text-yellow-800'
              }`}>
                {isOverLimit ? 'Usage Limit Exceeded' : 'Approaching Usage Limit'}
              </h4>
              <p className={`text-sm mt-1 ${
                isOverLimit ? 'text-red-700' : 'text-yellow-700'
              }`}>
                You've used {computeUsage.toLocaleString()} of {computeLimit.toLocaleString()} 
                compute minutes ({usagePercent.toFixed(0)}%).
                {isOverLimit && planConfig?.allowOverages && (
                  <span className="ml-1">
                    Overage charges apply at ${(planConfig.overagePricePerMinuteCents || 0) / 100}/minute.
                  </span>
                )}
              </p>
              {isNearLimit && !isOverLimit && (
                <button
                  onClick={() => window.location.href = '/pricing'}
                  className="text-sm underline mt-2 hover:no-underline"
                >
                  Upgrade for higher limits
                </button>
              )}
            </div>
          </div>
        </div>
      )}

      {/* Usage Metrics Grid */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        {/* Compute Minutes */}
        <div className="bg-gray-50 rounded-lg p-4">
          <h4 className="font-medium text-gray-900 mb-2">Compute Minutes</h4>
          <div className="flex items-end justify-between mb-2">
            <span className="text-2xl font-bold text-gray-900">
              {computeUsage.toLocaleString()}
            </span>
            <span className="text-sm text-gray-600">
              / {computeLimit.toLocaleString()}
            </span>
          </div>
          <div className="w-full bg-gray-200 rounded-full h-2">
            <div 
              className={`h-2 rounded-full transition-all ${
                isOverLimit ? 'bg-red-500' : isNearLimit ? 'bg-yellow-500' : 'bg-blue-500'
              }`}
              style={{ width: `${Math.min(100, usagePercent)}%` }}
            ></div>
          </div>
          <p className="text-xs text-gray-500 mt-1">
            {usagePercent.toFixed(1)}% used
          </p>
        </div>

        {/* Concurrent Jobs */}
        <div className="bg-gray-50 rounded-lg p-4">
          <h4 className="font-medium text-gray-900 mb-2">Concurrent Jobs</h4>
          <div className="flex items-end justify-between mb-2">
            <span className="text-2xl font-bold text-gray-900">
              {usage.currentConcurrentJobs || 0}
            </span>
            <span className="text-sm text-gray-600">
              / {planConfig?.concurrencyLimit || 0}
            </span>
          </div>
          <p className="text-xs text-gray-500">
            Peak this month: {usage.peakConcurrentJobs || 0}
          </p>
        </div>

        {/* Jobs Completed */}
        <div className="bg-gray-50 rounded-lg p-4">
          <h4 className="font-medium text-gray-900 mb-2">Jobs Completed</h4>
          <div className="flex items-end justify-between mb-2">
            <span className="text-2xl font-bold text-gray-900">
              {usage.jobsCompleted || 0}
            </span>
          </div>
          <p className="text-xs text-gray-500">
            Success rate: {usage.successRate || 0}%
          </p>
        </div>
      </div>

      {/* Usage Chart */}
      <div className="mt-6">
        <UsageChart 
          data={usage.dailyUsage || []} 
          limit={computeLimit}
        />
      </div>
    </div>
  )
}
```

### Billing History Component

```typescript
// components/billing/BillingHistorySection.tsx
import { useState, useEffect } from 'react'
import { DocumentArrowDownIcon, EyeIcon } from '@heroicons/react/24/outline'

interface BillingHistorySectionProps {
  customerId?: string
}

export function BillingHistorySection({ customerId }: BillingHistorySectionProps) {
  const [invoices, setInvoices] = useState<any[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    if (customerId) {
      loadInvoices()
    }
  }, [customerId])

  const loadInvoices = async () => {
    setLoading(true)
    try {
      const response = await fetch(`/api/billing/invoices?customerId=${customerId}`)
      if (response.ok) {
        const data = await response.json()
        setInvoices(data.invoices || [])
      }
    } catch (error) {
      console.error('Failed to load invoices:', error)
    } finally {
      setLoading(false)
    }
  }

  if (loading) {
    return <div className="animate-pulse bg-gray-200 rounded-lg h-64 w-full"></div>
  }

  return (
    <div className="bg-white rounded-lg border border-gray-200 p-6">
      <h2 className="text-xl font-semibold text-gray-900 mb-6">Billing History</h2>

      {invoices.length === 0 ? (
        <div className="text-center py-8">
          <p className="text-gray-600">No billing history available yet.</p>
        </div>
      ) : (
        <div className="overflow-hidden">
          <table className="min-w-full divide-y divide-gray-200">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Date
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Description
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Amount
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Status
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Actions
                </th>
              </tr>
            </thead>
            <tbody className="bg-white divide-y divide-gray-200">
              {invoices.map((invoice) => (
                <tr key={invoice.id}>
                  <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">
                    {new Date(invoice.created * 1000).toLocaleDateString()}
                  </td>
                  <td className="px-6 py-4 text-sm text-gray-900">
                    {invoice.description || `${invoice.lines?.data[0]?.description || 'Subscription'}`}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm text-gray-900">
                    ${(invoice.amount_paid / 100).toFixed(2)}
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap">
                    <span className={`inline-flex px-2 py-1 text-xs font-semibold rounded-full ${
                      invoice.status === 'paid' 
                        ? 'bg-green-100 text-green-800'
                        : invoice.status === 'open'
                        ? 'bg-yellow-100 text-yellow-800'
                        : 'bg-red-100 text-red-800'
                    }`}>
                      {invoice.status}
                    </span>
                  </td>
                  <td className="px-6 py-4 whitespace-nowrap text-sm font-medium">
                    <div className="flex space-x-2">
                      <button
                        onClick={() => window.open(invoice.hosted_invoice_url, '_blank')}
                        className="text-blue-600 hover:text-blue-700"
                        title="View Invoice"
                      >
                        <EyeIcon className="h-4 w-4" />
                      </button>
                      <button
                        onClick={() => window.open(invoice.invoice_pdf, '_blank')}
                        className="text-gray-600 hover:text-gray-700"
                        title="Download PDF"
                      >
                        <DocumentArrowDownIcon className="h-4 w-4" />
                      </button>
                    </div>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  )
}
```

## Dashboard Hooks

### Comprehensive Subscription Hook

```typescript
// hooks/useSubscription.ts
import { useState, useEffect } from 'react'
import { useAuth } from './useAuth'

export function useSubscription() {
  const [subscription, setSubscription] = useState<any>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const { user } = useAuth()

  useEffect(() => {
    if (user) {
      loadSubscription()
    } else {
      setSubscription(null)
      setLoading(false)
    }
  }, [user])

  const loadSubscription = async () => {
    if (!user) return

    setLoading(true)
    setError(null)

    try {
      const response = await fetch('/api/billing/subscription')
      
      if (response.ok) {
        const data = await response.json()
        setSubscription(data.subscription)
      } else if (response.status === 404) {
        // No subscription found - user is on free plan
        setSubscription(null)
      } else {
        throw new Error('Failed to load subscription')
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unknown error')
      setSubscription(null)
    } finally {
      setLoading(false)
    }
  }

  return {
    subscription,
    loading,
    error,
    reload: loadSubscription
  }
}
```

### Usage Data Hook

```typescript
// hooks/useUsageData.ts
import { useState, useEffect } from 'react'

export function useUsageData(userId: string, subscription: any) {
  const [usage, setUsage] = useState<any>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (userId && subscription) {
      loadUsage()
    }
  }, [userId, subscription])

  const loadUsage = async () => {
    setLoading(true)
    setError(null)

    try {
      const response = await fetch(`/api/usage/detailed?userId=${userId}`)
      
      if (response.ok) {
        const data = await response.json()
        setUsage(data)
      } else {
        throw new Error('Failed to load usage data')
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Unknown error')
    } finally {
      setLoading(false)
    }
  }

  return {
    usage,
    loading,
    error,
    reload: loadUsage
  }
}
```

## Testing Billing Dashboards

### Dashboard Component Tests

```typescript
// __tests__/components/billing/CurrentPlanSection.test.tsx
import { render, screen } from '@testing-library/react'
import { CurrentPlanSection } from '@/components/billing/CurrentPlanSection'

const mockSubscription = {
  id: 'sub_123',
  plan_id: 'starter',
  status: 'active',
  stripe_price_id: 'price_starter_monthly',
  current_period_end: new Date(Date.now() + 15 * 24 * 60 * 60 * 1000).toISOString(), // 15 days
  cancel_at_period_end: false,
  metadata: {}
}

describe('CurrentPlanSection', () => {
  it('renders subscription information correctly', () => {
    render(<CurrentPlanSection subscription={mockSubscription} loading={false} />)

    expect(screen.getByText('Starter Plan')).toBeInTheDocument()
    expect(screen.getByText('$19/mo')).toBeInTheDocument()
    expect(screen.getByText('active')).toBeInTheDocument()
  })

  it('shows scheduled change information', () => {
    const subscriptionWithScheduledChange = {
      ...mockSubscription,
      cancel_at_period_end: true,
      metadata: {
        scheduled_change: {
          planId: 'free',
          interval: 'month',
          effectiveAt: new Date(Date.now() + 15 * 24 * 60 * 60 * 1000).toISOString()
        }
      }
    }

    render(<CurrentPlanSection subscription={subscriptionWithScheduledChange} loading={false} />)

    expect(screen.getByText('(Changing)')).toBeInTheDocument()
    expect(screen.getByText(/→/)).toBeInTheDocument()
  })

  it('handles free plan display', () => {
    render(<CurrentPlanSection subscription={null} loading={false} />)

    expect(screen.getByText("You're currently on the free plan.")).toBeInTheDocument()
    expect(screen.getByText('Upgrade to Paid Plan')).toBeInTheDocument()
  })
})
```

### E2E Dashboard Tests

```typescript
// cypress/e2e/billing/billing-dashboard.cy.ts
describe('Billing Dashboard', () => {
  beforeEach(() => {
    cy.seedStarterUser({ email: 'dashboard-test@example.com' })
    cy.login('dashboard-test@example.com')
  })

  it('should display complete billing dashboard', () => {
    cy.visit('/billing')

    // Should show all main sections
    cy.get('[data-testid="current-plan-section"]').should('be.visible')
    cy.get('[data-testid="usage-section"]').should('be.visible')

    // Should show plan information
    cy.get('[data-testid="current-plan-name"]').should('contain', 'Starter')
    cy.get('[data-testid="current-plan-price"]').should('contain', '$19/mo')

    // Should show usage information
    cy.get('[data-testid="usage-compute-minutes"]').should('be.visible')
    cy.get('[data-testid="usage-concurrent-jobs"]').should('be.visible')

    // Should show customer portal button
    cy.get('[data-testid="customer-portal-button"]').should('be.visible')
  })

  it('should navigate between dashboard tabs', () => {
    cy.visit('/billing')

    // Test tab navigation
    cy.get('[data-testid="tab-usage"]').click()
    cy.get('[data-testid="detailed-usage-section"]').should('be.visible')

    cy.get('[data-testid="tab-history"]').click()
    cy.get('[data-testid="billing-history-section"]').should('be.visible')

    cy.get('[data-testid="tab-plans"]').click()
    cy.get('[data-testid="plan-management-section"]').should('be.visible')
  })

  it('should handle usage limit warnings', () => {
    // Seed user with high usage
    cy.seedUserWithHighUsage({ email: 'high-usage@example.com' })
    cy.login('high-usage@example.com')
    cy.visit('/billing')

    // Should show usage warning
    cy.get('[data-testid="usage-warning"]').should('be.visible')
    cy.get('[data-testid="usage-warning"]').should('contain', 'Approaching Usage Limit')

    // Should show upgrade link
    cy.get('[data-testid="upgrade-for-limits"]').should('be.visible')
  })
})
```

## Next Steps

In the next module, we'll cover implementing usage-based billing components and tracking consumption patterns.

## Key Takeaways

- Build comprehensive dashboards that combine subscription, usage, and billing data
- Use tabbed interfaces to organize complex billing information
- Implement real-time usage tracking and limit warnings
- Provide clear visual indicators for plan status and scheduled changes
- Use hooks for clean data management and state synchronization
- Test dashboard components thoroughly with various subscription states
- Handle loading and error states gracefully
- Integrate with both custom interfaces and Stripe Customer Portal
- Display billing history with download and view options
- Implement usage visualization for better user understanding
