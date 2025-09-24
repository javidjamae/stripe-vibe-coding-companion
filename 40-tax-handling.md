# Tax Handling with Stripe Tax

## Overview

This module covers implementing tax collection and compliance using Stripe Tax, including automatic tax calculation, tax registration management, and compliance reporting. We'll explore tax handling strategies for international SaaS billing.

## Tax Compliance Overview

### Why Tax Handling Matters

Modern SaaS businesses need to handle:
- **Sales Tax**: US state and local taxes
- **VAT**: European Union value-added tax
- **GST**: Goods and Services Tax (Canada, Australia, etc.)
- **Digital Services Tax**: Various international digital service taxes

### Stripe Tax Benefits

- **Automatic Calculation**: Real-time tax calculation based on customer location
- **Registration Management**: Handle tax registrations across jurisdictions
- **Compliance Reporting**: Generate tax reports for filing
- **Rate Updates**: Automatic tax rate updates
- **Exemption Handling**: Support for tax-exempt customers

## Basic Tax Configuration

### Enabling Stripe Tax

```typescript
// lib/tax/stripe-tax-config.ts
export async function enableStripeTax() {
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  // Configure tax settings
  const taxSettings = await stripe.tax.settings.update({
    defaults: {
      tax_behavior: 'inclusive', // or 'exclusive'
      tax_code: 'txcd_10000000' // Digital services tax code
    }
  })

  console.log('✅ Stripe Tax configured:', taxSettings)
  return taxSettings
}
```

### Tax-Aware Checkout Sessions

```typescript
// Enhanced checkout session with tax calculation
export async function createCheckoutSessionWithTax(
  userId: string,
  userEmail: string,
  planId: string,
  successUrl: string,
  cancelUrl: string,
  billingInterval: 'month' | 'year' = 'month'
) {
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  // Get plan and price information
  const priceId = getStripePriceId(planId, billingInterval)
  if (!priceId) {
    throw new Error('Invalid plan or billing interval')
  }

  // Create or get customer
  let customer = await getOrCreateStripeCustomer(userId, userEmail)

  // Create checkout session with automatic tax
  const session = await stripe.checkout.sessions.create({
    customer: customer.id,
    line_items: [{
      price: priceId,
      quantity: 1
    }],
    mode: 'subscription',
    success_url: successUrl,
    cancel_url: cancelUrl,
    
    // Enable automatic tax calculation
    automatic_tax: {
      enabled: true
    },
    
    // Customer address collection for tax calculation
    billing_address_collection: 'required',
    
    // Tax ID collection for business customers
    tax_id_collection: {
      enabled: true
    },

    metadata: {
      userId,
      planId
    },
    
    subscription_data: {
      metadata: {
        userId,
        planId
      }
    }
  })

  return session
}
```

## Tax Calculation for Upgrades

### Upgrade with Tax Preview

```typescript
// Enhanced proration preview with tax calculation
export async function getUpgradePreviewWithTax(
  userId: string,
  newPriceId: string
): Promise<{
  amountDue: number
  tax: number
  total: number
  currency: string
  taxBreakdown: any[]
}> {
  const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
    apiVersion: '2025-08-27.basil'
  })

  // Get current subscription
  const subscription = await getSubscriptionDetails(userId)
  if (!subscription?.stripe_subscription_id) {
    throw new Error('No active subscription found')
  }

  const current = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
  const currentItem = current.items?.data?.[0]
  
  if (!currentItem) {
    throw new Error('No subscription item found')
  }

  // Preview upcoming invoice with tax calculation
  const preview = await stripe.invoices.retrieveUpcoming({
    customer: current.customer as string,
    subscription: current.id,
    subscription_items: [
      { id: currentItem.id, price: newPriceId }
    ],
    subscription_proration_behavior: 'create_prorations',
    
    // Enable automatic tax calculation
    automatic_tax: {
      enabled: true
    }
  })

  const subtotal = (preview.subtotal ?? 0) / 100
  const tax = (preview.tax ?? 0) / 100
  const total = (preview.total ?? 0) / 100
  const currency = (preview.currency || 'usd').toUpperCase()

  // Extract tax breakdown
  const taxBreakdown = preview.total_tax_amounts?.map(taxAmount => ({
    jurisdiction: taxAmount.tax_rate?.jurisdiction,
    percentage: taxAmount.tax_rate?.percentage,
    amount: (taxAmount.amount ?? 0) / 100,
    inclusive: taxAmount.inclusive
  })) || []

  return {
    amountDue: subtotal,
    tax,
    total,
    currency,
    taxBreakdown
  }
}
```

### Tax-Aware Upgrade API

```typescript
// billing/upgrade-with-tax.ts - Framework-agnostic tax-aware upgrade
export async function handleUpgradeWithTax(request: Request): Promise<Response> {
  try {
    // Extract user context (implementation varies by framework)
    const user = await getUserFromRequest(request)
    if (!user) {
      return new Response(
        JSON.stringify({ error: 'Unauthorized' }),
        { status: 401, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const { newPlanId, newPriceId, billingInterval, customerAddress } = await request.json()
    
    // Validate inputs
    if (!newPlanId) {
      return new Response(
        JSON.stringify({ error: 'Missing newPlanId' }),
        { status: 400, headers: { 'Content-Type': 'application/json' } }
      )
    }

    const priceId = newPriceId || getStripePriceId(newPlanId, billingInterval || 'month')
    if (!priceId) {
      return new Response(
      JSON.stringify({ error: 'Invalid plan or billing interval' }),
      { status: 400, headers: { 'Content-Type': 'application/json' } }
    )

    // Get current subscription
    const subscription = await getSubscriptionDetails(user.id)
    if (!subscription?.stripe_subscription_id) {
      return new Response(
      JSON.stringify({ error: 'No active subscription found' ),
      { status: 404 })
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Update customer address for tax calculation if provided
    if (customerAddress && subscription.stripeCustomerId) {
      await stripe.customers.update(subscription.stripeCustomerId, {
        address: customerAddress
      })
    }

    // Get subscription and update with tax calculation
    const stripeSubscription = await stripe.subscriptions.retrieve(subscription.stripe_subscription_id)
    const subscriptionItemId = stripeSubscription.items.data[0].id

    const updatedSubscription = await stripe.subscriptions.update(subscription.stripe_subscription_id, {
      items: [{
        id: subscriptionItemId,
        price: priceId
      }],
      proration_behavior: 'create_prorations',
      
      // Enable automatic tax for this subscription
      automatic_tax: {
        enabled: true
      }
    })

    // Update database
    const { error: updateError } = await supabase
      .from('subscriptions')
      .update({
        plan_id: newPlanId,
        stripe_price_id: priceId,
        status: updatedSubscription.status,
        updated_at: new Date().toISOString()
      })
      .eq('stripe_subscription_id', subscription.stripe_subscription_id)

    if (updateError) {
      console.error('Failed to update subscription:', updateError)
      return new Response(
      JSON.stringify({ error: 'Failed to update subscription' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
    }

    return new Response(
      JSON.stringify({
      success: true,
      message: `Successfully upgraded to ${newPlanId}`,
      subscription: {
        id: updatedSubscription.id,
        status: updatedSubscription.status,
        taxEnabled: true
      }
    })

  } catch (error) {
    console.error('Tax-aware upgrade error:', error)
    return new Response(
      JSON.stringify({ error: 'Upgrade failed' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Tax Registration Management

### Tax Registration API

```typescript
// app/api/tax/registrations/route.ts
export async function GET() {
  try {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Get tax registrations
    const registrations = await stripe.tax.registrations.list()

    const formattedRegistrations = registrations.data.map(reg => ({
      id: reg.id,
      country: reg.country,
      state: reg.state,
      type: reg.type,
      status: reg.status,
      taxId: reg.tax_id,
      createdAt: new Date(reg.created * 1000).toISOString()
    }))

    return new Response(
      JSON.stringify({
      registrations: formattedRegistrations,
      count: registrations.data.length
    })

  } catch (error) {
    console.error('Failed to fetch tax registrations:', error)
    return new Response(
      JSON.stringify({ error: 'Failed to fetch registrations' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}

export async function POST(request: Request) {
  try {
    const { country, state, type, taxId } = await request.json()

    if (!country || !type) {
      return new Response(
      JSON.stringify({ 
        error: 'Country and type are required' 
      ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    // Create tax registration
    const registration = await stripe.tax.registrations.create({
      country,
      state,
      type,
      ...(taxId && { tax_id: taxId })
    })

    return new Response(
      JSON.stringify({
      success: true,
      registration: {
        id: registration.id,
        country: registration.country,
        state: registration.state,
        type: registration.type,
        status: registration.status
      }
    })

  } catch (error) {
    console.error('Failed to create tax registration:', error)
    
    if (error instanceof Stripe.errors.StripeError) {
      return new Response(
      JSON.stringify({ 
        error: error.message,
        code: error.code 
      ),
      { status: 400, headers: { 'Content-Type': 'application/json' } })
    }

    return new Response(
      JSON.stringify({ error: 'Failed to create registration' ),
      { status: 500, headers: { 'Content-Type': 'application/json' } })
  }
}
```

## Tax Exemption Handling

### Tax Exempt Customers

```typescript
// lib/tax/exemptions.ts
export class TaxExemptionManager {
  async setCustomerTaxExempt(
    customerId: string,
    exemptionType: 'exempt' | 'none' | 'reverse',
    exemptionDetails?: {
      exemptionNumber?: string
      exemptionReason?: string
      validUntil?: Date
    }
  ) {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    try {
      // Update customer tax exemption status
      await stripe.customers.update(customerId, {
        tax_exempt: exemptionType,
        metadata: {
          ...exemptionDetails && {
            tax_exemption_number: exemptionDetails.exemptionNumber,
            tax_exemption_reason: exemptionDetails.exemptionReason,
            tax_exemption_valid_until: exemptionDetails.validUntil?.toISOString()
          }
        }
      })

      // Log exemption change
      await this.logTaxExemptionChange(customerId, exemptionType, exemptionDetails)

      console.log(`✅ Tax exemption updated for customer ${customerId}: ${exemptionType}`)

    } catch (error) {
      console.error('Failed to update tax exemption:', error)
      throw error
    }
  }

  async validateTaxExemption(customerId: string): Promise<{
    isExempt: boolean
    exemptionType?: string
    expiresAt?: Date
    valid: boolean
  }> {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    try {
      const customer = await stripe.customers.retrieve(customerId)
      
      const exemptionType = (customer as any).tax_exempt
      const isExempt = exemptionType !== 'none'
      
      let valid = true
      let expiresAt: Date | undefined

      if (isExempt && (customer as any).metadata?.tax_exemption_valid_until) {
        expiresAt = new Date((customer as any).metadata.tax_exemption_valid_until)
        valid = expiresAt > new Date()
      }

      return {
        isExempt,
        exemptionType,
        expiresAt,
        valid
      }

    } catch (error) {
      console.error('Failed to validate tax exemption:', error)
      return { isExempt: false, valid: false }
    }
  }

  private async logTaxExemptionChange(
    customerId: string,
    exemptionType: string,
    details?: any
  ) {
    try {
      const supabase = createServerServiceRoleClient()
      
      await supabase
        .from('tax_exemption_log')
        .insert({
          customer_id: customerId,
          exemption_type: exemptionType,
          exemption_details: details,
          changed_at: new Date().toISOString(),
          changed_by: 'system' // Could track user who made the change
        })

    } catch (error) {
      console.error('Failed to log tax exemption change:', error)
    }
  }
}
```

## Tax-Inclusive Pricing

### Displaying Tax-Inclusive Prices

```typescript
// lib/pricing/tax-inclusive-display.ts
export class TaxInclusivePricing {
  async getPriceWithTax(
    priceId: string,
    customerLocation?: {
      country: string
      state?: string
      postalCode?: string
    }
  ): Promise<{
    basePrice: number
    taxAmount: number
    totalPrice: number
    currency: string
    taxRate?: number
  }> {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    try {
      // Get price details
      const price = await stripe.prices.retrieve(priceId)
      const baseAmount = price.unit_amount || 0
      const currency = price.currency

      if (!customerLocation) {
        // Return base price without tax calculation
        return {
          basePrice: baseAmount / 100,
          taxAmount: 0,
          totalPrice: baseAmount / 100,
          currency: currency.toUpperCase()
        }
      }

      // Calculate tax using Stripe Tax
      const calculation = await stripe.tax.calculations.create({
        currency: currency,
        line_items: [{
          amount: baseAmount,
          reference: priceId
        }],
        customer_details: {
          address: {
            country: customerLocation.country,
            state: customerLocation.state,
            postal_code: customerLocation.postalCode
          },
          address_source: 'billing'
        }
      })

      const taxAmount = calculation.tax_amount_exclusive || 0
      const totalAmount = calculation.amount_total || baseAmount

      return {
        basePrice: baseAmount / 100,
        taxAmount: taxAmount / 100,
        totalPrice: totalAmount / 100,
        currency: currency.toUpperCase(),
        taxRate: calculation.tax_breakdown?.[0]?.tax_rate?.percentage
      }

    } catch (error) {
      console.error('Tax calculation failed:', error)
      
      // Fallback to base price
      const price = await stripe.prices.retrieve(priceId)
      return {
        basePrice: (price.unit_amount || 0) / 100,
        taxAmount: 0,
        totalPrice: (price.unit_amount || 0) / 100,
        currency: (price.currency || 'usd').toUpperCase()
      }
    }
  }

  async getLocationFromIP(ipAddress: string): Promise<{
    country: string
    state?: string
    postalCode?: string
  } | null> {
    try {
      // Use IP geolocation service to determine customer location
      // This is a simplified example - use a proper geolocation service
      const response = await fetch(`https://ipapi.co/${ipAddress}/json/`)
      const data = await response.json()

      if (data.country_code) {
        return {
          country: data.country_code,
          state: data.region_code,
          postalCode: data.postal
        }
      }

      return null

    } catch (error) {
      console.error('IP geolocation failed:', error)
      return null
    }
  }
}
```

### Tax-Aware Pricing Display

```typescript
// components/pricing/TaxAwarePricing.tsx
import { useState, useEffect } from 'react'

interface TaxAwarePricingProps {
  planId: string
  billingInterval: 'month' | 'year'
  showTaxInclusive?: boolean
}

export function TaxAwarePricing({ 
  planId, 
  billingInterval, 
  showTaxInclusive = true 
}: TaxAwarePricingProps) {
  const [pricing, setPricing] = useState<any>(null)
  const [customerLocation, setCustomerLocation] = useState<any>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    loadPricingWithTax()
  }, [planId, billingInterval, customerLocation])

  const loadPricingWithTax = async () => {
    setLoading(true)
    try {
      const priceId = getStripePriceId(planId, billingInterval)
      if (!priceId) return

      // Get customer location
      if (!customerLocation) {
        const location = await detectCustomerLocation()
        setCustomerLocation(location)
        return // Will trigger useEffect again
      }

      // Get price with tax
      const response = await fetch('/api/pricing/with-tax', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          priceId,
          customerLocation
        })
      })

      if (response.ok) {
        const data = await response.json()
        setPricing(data)
      }

    } catch (error) {
      console.error('Failed to load tax-inclusive pricing:', error)
    } finally {
      setLoading(false)
    }
  }

  const detectCustomerLocation = async () => {
    try {
      const response = await fetch('/api/location/detect')
      if (response.ok) {
        return await response.json()
      }
    } catch (error) {
      console.error('Failed to detect location:', error)
    }
    return null
  }

  if (loading) {
    return <div className="animate-pulse bg-gray-200 h-8 w-24 rounded"></div>
  }

  if (!pricing) {
    // Fallback to base pricing
    const basePrice = getPlanPrice(planId, billingInterval) / 100
    return (
      <div>
        <span className="text-3xl font-bold">${basePrice}</span>
        <span className="text-gray-600">/{billingInterval === 'month' ? 'mo' : 'yr'}</span>
      </div>
    )
  }

  return (
    <div>
      <div>
        <span className="text-3xl font-bold">
          ${showTaxInclusive ? pricing.totalPrice : pricing.basePrice}
        </span>
        <span className="text-gray-600">
          /{billingInterval === 'month' ? 'mo' : 'yr'}
        </span>
      </div>
      
      {showTaxInclusive && pricing.taxAmount > 0 && (
        <div className="text-sm text-gray-600 mt-1">
          <div>Base price: ${pricing.basePrice}</div>
          <div>Tax: ${pricing.taxAmount} ({pricing.taxRate}%)</div>
          <div className="font-medium">Total: ${pricing.totalPrice}</div>
        </div>
      )}

      {pricing.taxBreakdown && pricing.taxBreakdown.length > 0 && (
        <div className="text-xs text-gray-500 mt-2">
          {pricing.taxBreakdown.map((tax: any, index: number) => (
            <div key={index}>
              {tax.jurisdiction}: {tax.percentage}% 
              {tax.inclusive ? ' (inclusive)' : ' (exclusive)'}
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
```

## Tax Reporting and Compliance

### Tax Report Generation

```typescript
// lib/tax/reporting.ts
export class TaxReporter {
  async generateTaxReport(
    startDate: Date,
    endDate: Date,
    jurisdiction?: string
  ) {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    try {
      // Get tax transactions for period
      const transactions = await stripe.tax.transactions.list({
        created: {
          gte: Math.floor(startDate.getTime() / 1000),
          lte: Math.floor(endDate.getTime() / 1000)
        },
        ...(jurisdiction && { 
          expand: ['data.line_items.tax_breakdown'] 
        })
      })

      // Aggregate by jurisdiction
      const reportData = transactions.data.reduce((acc, transaction) => {
        transaction.line_items?.data.forEach(lineItem => {
          lineItem.tax_breakdown?.forEach(taxBreakdown => {
            const jurisdiction = taxBreakdown.jurisdiction?.display_name || 'Unknown'
            
            if (!acc[jurisdiction]) {
              acc[jurisdiction] = {
                jurisdiction,
                totalTax: 0,
                totalSales: 0,
                transactionCount: 0,
                taxRate: taxBreakdown.tax_rate?.percentage || 0
              }
            }

            acc[jurisdiction].totalTax += (taxBreakdown.tax_amount || 0) / 100
            acc[jurisdiction].totalSales += (lineItem.amount || 0) / 100
            acc[jurisdiction].transactionCount += 1
          })
        })
        
        return acc
      }, {} as Record<string, any>)

      return {
        period: {
          start: startDate.toISOString(),
          end: endDate.toISOString()
        },
        summary: {
          totalTransactions: transactions.data.length,
          totalTaxCollected: Object.values(reportData).reduce((sum: number, data: any) => 
            sum + data.totalTax, 0),
          totalSales: Object.values(reportData).reduce((sum: number, data: any) => 
            sum + data.totalSales, 0),
          jurisdictionCount: Object.keys(reportData).length
        },
        byJurisdiction: Object.values(reportData)
      }

    } catch (error) {
      console.error('Tax report generation failed:', error)
      throw error
    }
  }

  async exportTaxReportCSV(reportData: any): Promise<string> {
    const headers = [
      'Jurisdiction',
      'Tax Rate (%)',
      'Total Sales ($)',
      'Total Tax ($)',
      'Transaction Count'
    ]

    const rows = reportData.byJurisdiction.map((data: any) => [
      data.jurisdiction,
      data.taxRate,
      data.totalSales.toFixed(2),
      data.totalTax.toFixed(2),
      data.transactionCount
    ])

    const csvContent = [
      headers.join(','),
      ...rows.map(row => row.join(','))
    ].join('\n')

    return csvContent
  }
}
```

## International Tax Compliance

### VAT Handling for EU Customers

```typescript
// lib/tax/vat-compliance.ts
export class VATCompliance {
  async validateVATNumber(vatNumber: string, country: string): Promise<{
    valid: boolean
    companyName?: string
    companyAddress?: string
  }> {
    try {
      // Use EU VAT validation service
      const response = await fetch(`https://ec.europa.eu/taxation_customs/vies/rest-api/ms/${country}/vat/${vatNumber}`)
      const data = await response.json()

      return {
        valid: data.valid === true,
        companyName: data.name,
        companyAddress: data.address
      }

    } catch (error) {
      console.error('VAT validation failed:', error)
      return { valid: false }
    }
  }

  async handleEUCustomerCheckout(
    customerId: string,
    vatNumber?: string,
    billingAddress?: any
  ) {
    const stripe = new Stripe(process.env.STRIPE_SECRET_KEY!, {
      apiVersion: '2025-08-27.basil'
    })

    try {
      const updateData: any = {}

      // Validate VAT number if provided
      if (vatNumber && billingAddress?.country) {
        const vatValidation = await this.validateVATNumber(vatNumber, billingAddress.country)
        
        if (vatValidation.valid) {
          // Valid VAT number - customer may be exempt from VAT
          updateData.tax_exempt = 'reverse' // Reverse charge mechanism
          updateData.metadata = {
            vat_number: vatNumber,
            vat_validated: 'true',
            vat_company_name: vatValidation.companyName
          }
        } else {
          // Invalid VAT number - charge VAT normally
          updateData.tax_exempt = 'none'
          updateData.metadata = {
            vat_number: vatNumber,
            vat_validated: 'false'
          }
        }
      }

      // Update billing address for tax calculation
      if (billingAddress) {
        updateData.address = billingAddress
      }

      await stripe.customers.update(customerId, updateData)

      console.log(`✅ EU customer tax configuration updated: ${customerId}`)

    } catch (error) {
      console.error('EU customer tax configuration failed:', error)
      throw error
    }
  }
}
```

## Tax Webhook Handling

### Tax Transaction Webhooks

```typescript
// Enhanced webhook handlers for tax events
export async function handleTaxTransactionCreated(transaction: any) {
  console.log('💰 Processing tax.transaction.created')
  console.log('Transaction ID:', transaction.id)
  console.log('Tax Amount:', transaction.tax_amount_exclusive)

  try {
    const supabase = createServerServiceRoleClient()

    // Store tax transaction for reporting
    const { error } = await supabase
      .from('tax_transactions')
      .insert({
        stripe_transaction_id: transaction.id,
        customer_id: transaction.customer,
        invoice_id: transaction.reference,
        tax_amount: (transaction.tax_amount_exclusive || 0) / 100,
        currency: transaction.currency,
        jurisdiction_breakdown: transaction.tax_breakdown || [],
        created_at: new Date(transaction.created * 1000).toISOString()
      })

    if (error) {
      console.error('❌ Error storing tax transaction:', error)
      return
    }

    console.log('✅ Tax transaction stored for reporting')

  } catch (error) {
    console.error('❌ Exception in handleTaxTransactionCreated:', error)
  }
}
```

## Testing Tax Integration

### Tax Calculation Tests

```typescript
// __tests__/integration/tax-handling.test.ts
describe('Tax Handling', () => {
  describe('Tax Calculation', () => {
    it('should calculate tax for US customers', async () => {
      const pricing = new TaxInclusivePricing()
      
      const result = await pricing.getPriceWithTax(
        'price_1S1EmGHxCxqKRRWFzsKZxGSY', // Starter monthly
        {
          country: 'US',
          state: 'CA',
          postalCode: '90210'
        }
      )

      expect(result.basePrice).toBe(19.00)
      expect(result.taxAmount).toBeGreaterThan(0) // Should have CA sales tax
      expect(result.totalPrice).toBeGreaterThan(result.basePrice)
      expect(result.currency).toBe('USD')
    })

    it('should handle VAT for EU customers', async () => {
      const pricing = new TaxInclusivePricing()
      
      const result = await pricing.getPriceWithTax(
        'price_1S1EmGHxCxqKRRWFzsKZxGSY',
        {
          country: 'DE', // Germany
          postalCode: '10115'
        }
      )

      expect(result.basePrice).toBe(19.00)
      expect(result.taxAmount).toBeGreaterThan(0) // Should have German VAT
      expect(result.taxRate).toBeCloseTo(19) // German VAT rate
    })

    it('should handle tax-exempt customers', async () => {
      const exemptionManager = new TaxExemptionManager()
      
      // Set customer as tax exempt
      await exemptionManager.setCustomerTaxExempt(
        'cus_test_exempt',
        'exempt',
        {
          exemptionNumber: 'EXEMPT-123',
          exemptionReason: 'Non-profit organization'
        }
      )

      const validation = await exemptionManager.validateTaxExemption('cus_test_exempt')
      
      expect(validation.isExempt).toBe(true)
      expect(validation.valid).toBe(true)
    })
  })
})
```

## Alternative: Manual Tax Handling

If you prefer not to use Stripe Tax:

### Manual Tax Rate Management

```typescript
// lib/tax/manual-tax.ts (Alternative approach)
export class ManualTaxCalculator {
  private taxRates: Record<string, Record<string, number>> = {
    'US': {
      'CA': 8.25, // California
      'NY': 8.00, // New York
      'TX': 6.25, // Texas
      'FL': 6.00  // Florida
    },
    'GB': {
      'default': 20.0 // UK VAT
    },
    'DE': {
      'default': 19.0 // German VAT
    }
  }

  calculateTax(
    amount: number,
    country: string,
    state?: string
  ): {
    taxAmount: number
    taxRate: number
    total: number
  } {
    const countryRates = this.taxRates[country] || {}
    const taxRate = countryRates[state || 'default'] || 0

    const taxAmount = amount * (taxRate / 100)
    const total = amount + taxAmount

    return {
      taxAmount: Math.round(taxAmount * 100) / 100,
      taxRate,
      total: Math.round(total * 100) / 100
    }
  }

  async updateTaxRates(rates: Record<string, Record<string, number>>) {
    // Store updated tax rates in database
    const supabase = createServerServiceRoleClient()
    
    for (const [country, stateRates] of Object.entries(rates)) {
      for (const [state, rate] of Object.entries(stateRates)) {
        await supabase
          .from('tax_rates')
          .upsert({
            country,
            state: state === 'default' ? null : state,
            rate,
            updated_at: new Date().toISOString()
          }, {
            onConflict: 'country,state'
          })
      }
    }

    // Update in-memory rates
    this.taxRates = rates
    console.log('✅ Tax rates updated')
  }
}
```

## Next Steps

In the next module, we'll cover implementing coupons and promotional pricing with Stripe.

## Key Takeaways

- **Use Stripe Tax** for automatic tax calculation and compliance
- **Enable automatic tax** in checkout sessions and subscriptions
- **Collect billing addresses** for accurate tax calculation
- **Handle tax exemptions** for business customers with valid tax IDs
- **Display tax-inclusive pricing** when possible for transparency
- **Store tax transactions** for compliance reporting and auditing
- **Validate VAT numbers** for EU business customers
- **Implement location detection** for accurate tax calculation
- **Test tax calculations** with various customer locations
- **Consider manual tax handling** only if Stripe Tax doesn't meet your needs
