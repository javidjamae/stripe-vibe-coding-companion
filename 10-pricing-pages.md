# Building Dynamic Pricing Pages

## Overview

This module covers building dynamic pricing pages that use your plan configuration system to display pricing information to users. We'll explore how to create flexible, responsive pricing components that handle multiple billing intervals and plan variations.

## Pricing Page Architecture

Your pricing page should be driven by your plan configuration data, making it easy to update pricing without code changes:

```
Plan Configuration → Pricing Display Logic → React Components → User Interface
```

### Core Components

1. **PricingPage**: Main container component
2. **PlanCard**: Individual plan display
3. **BillingToggle**: Monthly/Annual switch
4. **FeatureList**: Plan features display
5. **ActionButton**: Subscribe/Upgrade buttons

## Dynamic Pricing Components

### Main Pricing Page Component

```typescript
// app/pricing/page.tsx
'use client'

import { useState, useEffect } from 'react'
import { PlanCard } from '@/components/pricing/PlanCard'
import { BillingToggle } from '@/components/pricing/BillingToggle'
import { getPlanDisplayData, getAllPlans } from '@/lib/plan-config'

export default function PricingPage() {
  const [billingInterval, setBillingInterval] = useState<'month' | 'year'>('month')
  const [plans, setPlans] = useState<any[]>([])
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    loadPlans()
  }, [billingInterval])

  const loadPlans = async () => {
    setLoading(true)
    try {
      const allPlans = getAllPlans()
      const planData = Object.keys(allPlans).map(planId => 
        getPlanDisplayData(planId, billingInterval)
      ).filter(Boolean)

      setPlans(planData)
    } catch (error) {
      console.error('Failed to load plans:', error)
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="py-12 bg-gray-50">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 lg:px-8">
        {/* Header */}
        <div className="text-center">
          <h1 className="text-4xl font-bold text-gray-900 sm:text-5xl">
            Simple, Transparent Pricing
          </h1>
          <p className="mt-4 text-xl text-gray-600 max-w-3xl mx-auto">
            Choose the perfect plan for your needs. Upgrade or downgrade at any time.
          </p>
        </div>

        {/* Billing Toggle */}
        <div className="mt-12 flex justify-center">
          <BillingToggle
            interval={billingInterval}
            onChange={setBillingInterval}
          />
        </div>

        {/* Plans Grid */}
        {loading ? (
          <div className="mt-12 text-center">
            <div className="inline-block animate-spin rounded-full h-8 w-8 border-b-2 border-blue-600"></div>
            <p className="mt-2 text-gray-600">Loading plans...</p>
          </div>
        ) : (
          <div className="mt-12 grid grid-cols-1 gap-8 sm:grid-cols-2 lg:grid-cols-4">
            {plans.map((plan) => (
              <PlanCard
                key={plan.id}
                plan={plan}
                billingInterval={billingInterval}
                featured={plan.id === 'pro'} // Highlight Pro plan
              />
            ))}
          </div>
        )}

        {/* FAQ Section */}
        <div className="mt-20">
          <PricingFAQ />
        </div>
      </div>
    </div>
  )
}
```

### Billing Interval Toggle

```typescript
// components/pricing/BillingToggle.tsx
interface BillingToggleProps {
  interval: 'month' | 'year'
  onChange: (interval: 'month' | 'year') => void
}

export function BillingToggle({ interval, onChange }: BillingToggleProps) {
  return (
    <div className="relative bg-gray-100 rounded-lg p-1 flex">
      <button
        onClick={() => onChange('month')}
        className={`relative px-6 py-2 text-sm font-medium rounded-md transition-all ${
          interval === 'month'
            ? 'bg-white text-gray-900 shadow-sm'
            : 'text-gray-600 hover:text-gray-900'
        }`}
      >
        Monthly
      </button>
      <button
        onClick={() => onChange('year')}
        className={`relative px-6 py-2 text-sm font-medium rounded-md transition-all ${
          interval === 'year'
            ? 'bg-white text-gray-900 shadow-sm'
            : 'text-gray-600 hover:text-gray-900'
        }`}
      >
        <span>Annual</span>
        <span className="ml-1 text-xs text-green-600 font-semibold">
          Save 20%
        </span>
      </button>
    </div>
  )
}
```

### Plan Card Component

```typescript
// components/pricing/PlanCard.tsx
import { useState } from 'react'
import { CheckIcon } from '@heroicons/react/24/outline'
import { useAuth } from '@/hooks/useAuth'
import { useCheckout } from '@/hooks/useCheckout'

interface PlanCardProps {
  plan: {
    id: string
    name: string
    price: string
    priceRaw: number
    features: {
      computeMinutes: number
      concurrency: number
      overages: boolean
      overagePrice?: number
    }
    savings?: {
      savingsPercent: number
      savingsAmount: number
    }
    isFree: boolean
    availableIntervals: ('month' | 'year')[]
  }
  billingInterval: 'month' | 'year'
  featured?: boolean
  currentPlan?: string
}

export function PlanCard({ plan, billingInterval, featured, currentPlan }: PlanCardProps) {
  const [loading, setLoading] = useState(false)
  const { user } = useAuth()
  const { createCheckoutSession } = useCheckout()

  const isCurrentPlan = currentPlan === plan.id
  const isAvailable = plan.availableIntervals.includes(billingInterval)

  const handleSelectPlan = async () => {
    if (isCurrentPlan || !isAvailable) return

    if (!user) {
      // Redirect to sign up
      window.location.href = '/auth/signup'
      return
    }

    setLoading(true)
    try {
      await createCheckoutSession(plan.id, billingInterval)
    } catch (error) {
      console.error('Failed to start checkout:', error)
    } finally {
      setLoading(false)
    }
  }

  const getButtonText = () => {
    if (loading) return 'Loading...'
    if (isCurrentPlan) return 'Current Plan'
    if (!isAvailable) return 'Not Available'
    if (!user) return 'Get Started'
    return 'Upgrade'
  }

  const getButtonStyle = () => {
    if (isCurrentPlan) {
      return 'bg-green-100 text-green-800 cursor-not-allowed'
    }
    if (!isAvailable) {
      return 'bg-gray-100 text-gray-400 cursor-not-allowed'
    }
    if (featured) {
      return 'bg-blue-600 text-white hover:bg-blue-700'
    }
    return 'bg-gray-900 text-white hover:bg-gray-800'
  }

  return (
    <div className={`relative rounded-2xl border ${
      featured 
        ? 'border-blue-500 shadow-lg ring-1 ring-blue-500' 
        : 'border-gray-200'
    } bg-white p-8`}>
      {featured && (
        <div className="absolute -top-3 left-1/2 transform -translate-x-1/2">
          <span className="bg-blue-500 text-white px-4 py-1 rounded-full text-sm font-medium">
            Most Popular
          </span>
        </div>
      )}

      {/* Plan Header */}
      <div className="text-center">
        <h3 className="text-lg font-semibold text-gray-900">{plan.name}</h3>
        
        <div className="mt-4">
          <span className="text-4xl font-bold text-gray-900">{plan.price}</span>
          {!plan.isFree && (
            <span className="text-gray-600">
              /{billingInterval === 'month' ? 'mo' : 'yr'}
            </span>
          )}
        </div>

        {plan.savings && billingInterval === 'year' && (
          <div className="mt-2">
            <span className="text-sm text-green-600 font-medium">
              Save {plan.savings.savingsPercent}% annually
            </span>
          </div>
        )}
      </div>

      {/* Features List */}
      <ul className="mt-8 space-y-4">
        <li className="flex items-start">
          <CheckIcon className="flex-shrink-0 w-5 h-5 text-green-500 mt-0.5" />
          <span className="ml-3 text-gray-700">
            {plan.features.computeMinutes.toLocaleString()} compute minutes/month
          </span>
        </li>
        
        <li className="flex items-start">
          <CheckIcon className="flex-shrink-0 w-5 h-5 text-green-500 mt-0.5" />
          <span className="ml-3 text-gray-700">
            {plan.features.concurrency} concurrent job{plan.features.concurrency !== 1 ? 's' : ''}
          </span>
        </li>

        {plan.features.overages ? (
          <li className="flex items-start">
            <CheckIcon className="flex-shrink-0 w-5 h-5 text-green-500 mt-0.5" />
            <span className="ml-3 text-gray-700">
              Overages available at ${(plan.features.overagePrice || 0) / 100}/minute
            </span>
          </li>
        ) : (
          <li className="flex items-start">
            <span className="flex-shrink-0 w-5 h-5 text-gray-300 mt-0.5">✗</span>
            <span className="ml-3 text-gray-500">
              No overages (hard limit)
            </span>
          </li>
        )}

        <li className="flex items-start">
          <CheckIcon className="flex-shrink-0 w-5 h-5 text-green-500 mt-0.5" />
          <span className="ml-3 text-gray-700">
            API access & webhooks
          </span>
        </li>

        {plan.id !== 'free' && (
          <li className="flex items-start">
            <CheckIcon className="flex-shrink-0 w-5 h-5 text-green-500 mt-0.5" />
            <span className="ml-3 text-gray-700">
              Priority support
            </span>
          </li>
        )}
      </ul>

      {/* Action Button */}
      <button
        onClick={handleSelectPlan}
        disabled={loading || isCurrentPlan || !isAvailable}
        className={`mt-8 w-full py-3 px-4 rounded-lg font-medium transition-colors ${getButtonStyle()}`}
      >
        {getButtonText()}
      </button>

      {!isAvailable && (
        <p className="mt-2 text-xs text-gray-500 text-center">
          {billingInterval === 'year' ? 'Annual billing' : 'Monthly billing'} not available for this plan
        </p>
      )}
    </div>
  )
}
```

### Feature Comparison Table

```typescript
// components/pricing/FeatureComparison.tsx
export function FeatureComparison() {
  const plans = getAllPlans()
  const planIds = Object.keys(plans)

  const features = [
    {
      name: 'Compute Minutes',
      getValue: (planId: string) => {
        const plan = plans[planId]
        return plan.includedComputeMinutes.toLocaleString()
      }
    },
    {
      name: 'Concurrent Jobs',
      getValue: (planId: string) => {
        const plan = plans[planId]
        return plan.concurrencyLimit.toString()
      }
    },
    {
      name: 'Overages',
      getValue: (planId: string) => {
        const plan = plans[planId]
        return plan.allowOverages ? '✓' : '✗'
      }
    },
    {
      name: 'API Access',
      getValue: () => '✓'
    },
    {
      name: 'Webhooks',
      getValue: () => '✓'
    },
    {
      name: 'Priority Support',
      getValue: (planId: string) => planId !== 'free' ? '✓' : '✗'
    }
  ]

  return (
    <div className="mt-20">
      <h2 className="text-2xl font-bold text-center mb-8">Feature Comparison</h2>
      
      <div className="overflow-x-auto">
        <table className="w-full border-collapse border border-gray-300">
          <thead>
            <tr className="bg-gray-50">
              <th className="border border-gray-300 px-4 py-2 text-left">Feature</th>
              {planIds.map(planId => (
                <th key={planId} className="border border-gray-300 px-4 py-2 text-center">
                  {plans[planId].name}
                </th>
              ))}
            </tr>
          </thead>
          <tbody>
            {features.map((feature, index) => (
              <tr key={index} className={index % 2 === 0 ? 'bg-white' : 'bg-gray-50'}>
                <td className="border border-gray-300 px-4 py-2 font-medium">
                  {feature.name}
                </td>
                {planIds.map(planId => (
                  <td key={planId} className="border border-gray-300 px-4 py-2 text-center">
                    {feature.getValue(planId)}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}
```

## Pricing Page Hooks

### Custom Pricing Hook

```typescript
// hooks/usePricing.ts
import { useState, useEffect } from 'react'
import { getAllPlans, getPlanDisplayData } from '@/lib/plan-config'

export function usePricing(billingInterval: 'month' | 'year') {
  const [plans, setPlans] = useState<any[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    loadPricing()
  }, [billingInterval])

  const loadPricing = async () => {
    setLoading(true)
    setError(null)

    try {
      const allPlans = getAllPlans()
      const planData = Object.keys(allPlans)
        .map(planId => getPlanDisplayData(planId, billingInterval))
        .filter(Boolean)
        .sort((a, b) => {
          // Sort by price: free first, then by price ascending
          if (a.isFree) return -1
          if (b.isFree) return 1
          return a.priceRaw - b.priceRaw
        })

      setPlans(planData)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Failed to load pricing')
    } finally {
      setLoading(false)
    }
  }

  return {
    plans,
    loading,
    error,
    reload: loadPricing
  }
}
```

### Current Plan Hook

```typescript
// hooks/useCurrentPlan.ts
import { useState, useEffect } from 'react'
import { useAuth } from './useAuth'
import { getSubscriptionDetails } from '@/lib/billing'

export function useCurrentPlan() {
  const [currentPlan, setCurrentPlan] = useState<string | null>(null)
  const [loading, setLoading] = useState(true)
  const { user } = useAuth()

  useEffect(() => {
    if (user) {
      loadCurrentPlan()
    } else {
      setCurrentPlan(null)
      setLoading(false)
    }
  }, [user])

  const loadCurrentPlan = async () => {
    if (!user) return

    try {
      const subscription = await getSubscriptionDetails(user.id)
      setCurrentPlan(subscription?.plan_id || null)
    } catch (error) {
      console.error('Failed to load current plan:', error)
      setCurrentPlan(null)
    } finally {
      setLoading(false)
    }
  }

  return {
    currentPlan,
    loading,
    reload: loadCurrentPlan
  }
}
```

## Pricing FAQ Component

```typescript
// components/pricing/PricingFAQ.tsx
const faqs = [
  {
    question: "Can I change my plan at any time?",
    answer: "Yes! You can upgrade immediately or schedule downgrades for the end of your billing period. Upgrades are prorated, so you only pay for the time remaining in your current cycle."
  },
  {
    question: "What happens if I exceed my compute minutes?",
    answer: "If you're on a plan that allows overages (Starter, Pro, Scale), you'll be charged per-minute overages. Free plan users hit a hard limit and jobs will queue until the next billing period."
  },
  {
    question: "How does annual billing work?",
    answer: "Annual plans give you 2 months free compared to monthly billing. You're billed upfront for the full year, and your compute minutes reset each month."
  },
  {
    question: "Can I cancel anytime?",
    answer: "Absolutely. You can cancel your subscription at any time from your billing dashboard. You'll continue to have access until the end of your current billing period."
  },
  {
    question: "Do you offer refunds?",
    answer: "We offer prorated refunds for annual subscriptions if you cancel within the first 30 days. Monthly subscriptions are not refunded but you keep access until period end."
  }
]

export function PricingFAQ() {
  const [openIndex, setOpenIndex] = useState<number | null>(null)

  return (
    <div className="max-w-3xl mx-auto">
      <h2 className="text-2xl font-bold text-center mb-8">Frequently Asked Questions</h2>
      
      <div className="space-y-4">
        {faqs.map((faq, index) => (
          <div key={index} className="border border-gray-200 rounded-lg">
            <button
              onClick={() => setOpenIndex(openIndex === index ? null : index)}
              className="w-full px-6 py-4 text-left flex justify-between items-center hover:bg-gray-50"
            >
              <span className="font-medium text-gray-900">{faq.question}</span>
              <span className="text-gray-400">
                {openIndex === index ? '−' : '+'}
              </span>
            </button>
            
            {openIndex === index && (
              <div className="px-6 pb-4">
                <p className="text-gray-600">{faq.answer}</p>
              </div>
            )}
          </div>
        ))}
      </div>
    </div>
  )
}
```

## Responsive Design Patterns

### Mobile-Optimized Pricing

```typescript
// components/pricing/MobilePricingCard.tsx
export function MobilePricingCard({ plan, billingInterval, onSelect }: any) {
  return (
    <div className="bg-white rounded-lg border border-gray-200 p-6">
      <div className="text-center mb-6">
        <h3 className="text-xl font-semibold">{plan.name}</h3>
        <div className="mt-2">
          <span className="text-3xl font-bold">{plan.price}</span>
          {!plan.isFree && (
            <span className="text-gray-500 ml-1">
              /{billingInterval === 'month' ? 'mo' : 'yr'}
            </span>
          )}
        </div>
      </div>

      {/* Condensed feature list for mobile */}
      <div className="space-y-3 mb-6">
        <div className="flex justify-between">
          <span className="text-gray-600">Compute Minutes</span>
          <span className="font-medium">{plan.features.computeMinutes.toLocaleString()}</span>
        </div>
        <div className="flex justify-between">
          <span className="text-gray-600">Concurrent Jobs</span>
          <span className="font-medium">{plan.features.concurrency}</span>
        </div>
        <div className="flex justify-between">
          <span className="text-gray-600">Overages</span>
          <span className="font-medium">{plan.features.overages ? '✓' : '✗'}</span>
        </div>
      </div>

      <button
        onClick={() => onSelect(plan.id)}
        className="w-full bg-blue-600 text-white py-3 rounded-lg font-medium hover:bg-blue-700"
      >
        Select {plan.name}
      </button>
    </div>
  )
}
```

## Testing Pricing Pages

### Unit Tests

```typescript
// __tests__/components/PlanCard.test.tsx
import { render, screen, fireEvent } from '@testing-library/react'
import { PlanCard } from '@/components/pricing/PlanCard'

const mockPlan = {
  id: 'starter',
  name: 'Starter Plan',
  price: '$19/mo',
  priceRaw: 1900,
  features: {
    computeMinutes: 2000,
    concurrency: 3,
    overages: true,
    overagePrice: 10
  },
  isFree: false,
  availableIntervals: ['month', 'year'] as ('month' | 'year')[]
}

describe('PlanCard', () => {
  it('renders plan information correctly', () => {
    render(
      <PlanCard
        plan={mockPlan}
        billingInterval="month"
      />
    )

    expect(screen.getByText('Starter Plan')).toBeInTheDocument()
    expect(screen.getByText('$19/mo')).toBeInTheDocument()
    expect(screen.getByText('2,000 compute minutes/month')).toBeInTheDocument()
    expect(screen.getByText('3 concurrent jobs')).toBeInTheDocument()
  })

  it('shows current plan badge when appropriate', () => {
    render(
      <PlanCard
        plan={mockPlan}
        billingInterval="month"
        currentPlan="starter"
      />
    )

    expect(screen.getByText('Current Plan')).toBeInTheDocument()
    expect(screen.getByRole('button')).toBeDisabled()
  })

  it('handles plan selection', () => {
    const mockCheckout = jest.fn()
    jest.mock('@/hooks/useCheckout', () => ({
      useCheckout: () => ({ createCheckoutSession: mockCheckout })
    }))

    render(
      <PlanCard
        plan={mockPlan}
        billingInterval="month"
      />
    )

    fireEvent.click(screen.getByRole('button'))
    // Test would verify checkout flow initiation
  })
})
```

### E2E Tests

```typescript
// cypress/e2e/pricing-page.cy.ts
describe('Pricing Page', () => {
  it('displays all plans with correct pricing', () => {
    cy.visit('/pricing')

    // Should show all plan cards
    cy.get('[data-testid="plan-card"]').should('have.length', 4)
    
    // Should show monthly pricing by default
    cy.get('[data-testid="free-plan"]').should('contain', 'Free')
    cy.get('[data-testid="starter-plan"]').should('contain', '$19/mo')
    cy.get('[data-testid="pro-plan"]').should('contain', '$89/mo')
    cy.get('[data-testid="scale-plan"]').should('contain', '$349/mo')
  })

  it('switches between monthly and annual billing', () => {
    cy.visit('/pricing')

    // Switch to annual
    cy.get('[data-testid="billing-toggle-annual"]').click()

    // Should show annual pricing
    cy.get('[data-testid="starter-plan"]').should('contain', '$129/yr')
    cy.get('[data-testid="pro-plan"]').should('contain', '$599/yr')
    
    // Should show savings indicator
    cy.get('[data-testid="savings-indicator"]').should('be.visible')
  })

  it('handles plan selection for authenticated users', () => {
    cy.login('test@example.com')
    cy.visit('/pricing')

    // Click on Starter plan
    cy.get('[data-testid="starter-select-button"]').click()

    // Should redirect to checkout
    cy.url().should('include', 'checkout.stripe.com')
  })
})
```

## Next Steps

In the next module, we'll cover plan validation logic and how to implement business rules for plan changes.

## Key Takeaways

- Build pricing pages dynamically from plan configuration
- Support multiple billing intervals with toggle functionality
- Create responsive, accessible pricing components
- Handle user authentication states in pricing flows
- Implement feature comparison tables for clarity
- Add FAQ sections to address common questions
- Test pricing pages thoroughly with unit and E2E tests
- Use hooks for clean separation of concerns
- Optimize for mobile devices with condensed layouts
- Handle loading and error states gracefully
