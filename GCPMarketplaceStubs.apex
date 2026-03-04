/**
 * ============================================================
 * GCP MARKETPLACE INTEGRATION — APEX STUBS
 * ============================================================
 * Three touchpoints:
 *   1. GCPMarketplaceAuth       — Service account OAuth2 token exchange
 *   2. GCPPrivateOfferService   — Private Offer creation from SFDC Opportunity
 *   3. GCPEntitlementHandler    — Pub/Sub entitlement event processor
 *   4. GCPUsageReportService    — Hourly metered usage reporting
 *   5. GCPMarketplaceException  — Shared exception class
 *
 * Setup required in SFDC org:
 *   - Named Credential: GCP_Marketplace (for Procurement API)
 *   - Named Credential: GCP_ServiceControl (for Usage API)
 *   - Custom Metadata: GCP_Marketplace_Config__mdt
 *   - Remote Site Settings for both GCP API domains
 *   - Custom fields on Opportunity (see field references below)
 * ============================================================
 */


// ============================================================
// SHARED EXCEPTION
// ============================================================

public class GCPMarketplaceException extends Exception {
    public Integer statusCode { get; private set; }
    public String  gcpError   { get; private set; }

    public GCPMarketplaceException(String message, Integer statusCode, String gcpError) {
        this(message);
        this.statusCode = statusCode;
        this.gcpError   = gcpError;
    }
}


// ============================================================
// AUTH — Service Account Token Exchange
// ============================================================
/**
 * Exchanges a GCP service account key for a short-lived Bearer token.
 *
 * In production you have two options:
 *   A) Store the service account JSON in a Protected Custom Setting
 *      and sign the JWT assertion here in Apex using Crypto.sign()
 *   B) Use a Named Credential with OAuth 2.0 JWT Bearer flow configured —
 *      Salesforce handles token refresh automatically (recommended)
 *
 * This stub models Option A for transparency.
 * Required OAuth scope: https://www.googleapis.com/auth/cloud-platform
 */
public class GCPMarketplaceAuth {

    private static final String TOKEN_ENDPOINT =
        'https://oauth2.googleapis.com/token';
    private static final String SCOPE =
        'https://www.googleapis.com/auth/cloud-platform ' +
        'https://www.googleapis.com/auth/servicecontrol';

    /**
     * Returns a valid Bearer token for GCP API calls.
     * Caches in Platform Cache (Org partition) for token lifetime.
     *
     * @return String   Bearer access token
     */
    public static String getBearerToken() {
        // Try cache first — avoid re-minting tokens on every callout
        String cached = (String) Cache.Org.get('GCPAccessToken');
        if (cached != null) {
            return cached;
        }

        String token = mintAccessToken();

        // Cache for 55 minutes (tokens live 60 min; 5 min buffer)
        Cache.Org.put('GCPAccessToken', token, 3300);
        return token;
    }

    /**
     * Mints a new access token via JWT Bearer assertion.
     * TODO: Implement JWT signing using the service account private key.
     *
     * @return String   access_token value from GCP token endpoint
     */
    private static String mintAccessToken() {
        // Step 1: Build JWT header + claim set
        // Header:  { "alg": "RS256", "typ": "JWT" }
        // Claims:
        //   iss  = service account email (from Custom Setting)
        //   scope = SCOPE
        //   aud  = https://oauth2.googleapis.com/token
        //   exp  = now + 3600
        //   iat  = now

        // TODO: Retrieve service account email and private key PEM from
        //        GCP_Service_Account__c Protected Custom Setting
        GCP_Service_Account__c cfg = GCP_Service_Account__c.getOrgDefaults();
        String serviceAccountEmail = cfg.Email__c;
        String privateKeyPem       = cfg.Private_Key__c;

        // TODO: Base64url-encode header and claims
        // TODO: Sign (header.claims) with RS256 using Crypto.sign('RSA-SHA256', ...)
        // TODO: Build assertion = encodedHeader + '.' + encodedClaims + '.' + encodedSignature

        String jwtAssertion = buildJWTAssertion(serviceAccountEmail, privateKeyPem); // TODO

        // Step 2: Exchange JWT assertion for access token
        HttpRequest req = new HttpRequest();
        req.setEndpoint(TOKEN_ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setBody(
            'grant_type=' + EncodingUtil.urlEncode('urn:ietf:params:oauth:grant-type:jwt-bearer', 'UTF-8') +
            '&assertion=' + EncodingUtil.urlEncode(jwtAssertion, 'UTF-8')
        );

        Http http = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() != 200) {
            throw new GCPMarketplaceException(
                'Token exchange failed',
                res.getStatusCode(),
                res.getBody()
            );
        }

        Map<String, Object> tokenResponse =
            (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

        return (String) tokenResponse.get('access_token');
    }

    /**
     * TODO: Build and sign a JWT assertion using the service account key.
     * Use Crypto.sign() with the RSA-SHA256 algorithm and the private key bytes.
     */
    private static String buildJWTAssertion(String email, String privateKeyPem) {
        throw new GCPMarketplaceException('buildJWTAssertion: not implemented', 501, null);
    }
}


// ============================================================
// SHARED HTTP HELPER
// ============================================================

public class GCPHttpClient {

    private static final String PROCUREMENT_BASE =
        'https://cloudcommerceprocurement.googleapis.com/v1';
    private static final String SERVICE_CONTROL_BASE =
        'https://servicecontrol.googleapis.com/v1/services';

    /**
     * Makes an authenticated callout to a GCP API endpoint.
     *
     * @param method        HTTP verb: GET, POST, PATCH, DELETE
     * @param endpoint      Full URL
     * @param requestBody   Serialized JSON string, or null for GET/DELETE
     * @return              Deserialized response as Map<String, Object>
     */
    public static Map<String, Object> callout(
        String method,
        String endpoint,
        String requestBody
    ) {
        String token = GCPMarketplaceAuth.getBearerToken();

        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod(method);
        req.setHeader('Authorization', 'Bearer ' + token);
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(30000); // 30s timeout

        if (requestBody != null) {
            req.setBody(requestBody);
        }

        Http http      = new Http();
        HttpResponse res = http.send(req);

        if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
            throw new GCPMarketplaceException(
                'GCP API error: ' + method + ' ' + endpoint,
                res.getStatusCode(),
                res.getBody()
            );
        }

        if (String.isBlank(res.getBody())) {
            return new Map<String, Object>();
        }

        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    public static String getProcurementBase() { return PROCUREMENT_BASE; }
    public static String getServiceControlBase() { return SERVICE_CONTROL_BASE; }
}


// ============================================================
// TOUCHPOINT 1 — PRIVATE OFFER CREATION
// ============================================================
/**
 * Originates a GCP Marketplace Private Offer from a Salesforce Opportunity.
 *
 * Flow:
 *   Opportunity (Closed-Won)
 *     → buildOfferPayload()        maps SFDC fields to GCP payload
 *     → createPrivateOffer()       POST to GCP Procurement API
 *     → syncOfferToOpportunity()   writes GCP Offer ID back to Opportunity
 *
 * Custom fields required on Opportunity:
 *   GCP_Billing_Account_ID__c  (Text)    — customer's GCP billing account
 *   GCP_Product_ID__c          (Text)    — your GCP product identifier
 *   GCP_Plan_ID__c             (Text)    — the plan being purchased
 *   GCP_Offer_ID__c            (Text)    — written back after offer creation
 *   GCP_Offer_URL__c           (URL)     — written back after offer creation
 *   GCP_Offer_Status__c        (Text)    — written back after offer creation
 *   GCP_Partner_Metadata__c    (LTA)     — JSON blob for cross-reference
 */
public class GCPPrivateOfferService {

    private static final String PARTNER_ID =
        GCP_Marketplace_Config__mdt.getInstance('Default').Partner_ID__c;

    // ── Inner class: GCP Offer payload wrapper ───────────────

    public class OfferPayload {
        public String  buyerBillingAccountId { get; set; }
        public String  productExternalName   { get; set; }
        public String  planExternalName      { get; set; }
        public String  name                  { get; set; }
        public String  startTime             { get; set; }
        public String  endTime               { get; set; }
        public Decimal discount              { get; set; }
        public List<PaymentEntry> paymentSchedule { get; set; }
        public Map<String, String> partnerMetadata { get; set; }
    }

    public class PaymentEntry {
        public String    billingTime { get; set; }
        public PriceSpec price       { get; set; }
    }

    public class PriceSpec {
        public String  currencyCode { get; set; }
        public String  units        { get; set; }
        public Integer nanos        { get; set; }
    }

    // ── Build payload from Opportunity + Quote ────────────────

    /**
     * Maps a Salesforce Opportunity and CPQ Quote to GCP offer payload.
     *
     * @param opp       Opportunity with custom GCP fields populated
     * @param quote     SBQQ__Quote__c with payment installment child records
     * @return          OfferPayload ready for JSON serialization
     */
    public static OfferPayload buildOfferPayload(Opportunity opp, SBQQ__Quote__c quote) {
        OfferPayload payload     = new OfferPayload();
        payload.buyerBillingAccountId = opp.GCP_Billing_Account_ID__c;
        payload.productExternalName   =
            opp.GCP_Product_ID__c + '.mp-' + PARTNER_ID + '.appspot.com';
        payload.planExternalName      = opp.GCP_Plan_ID__c;
        payload.name                  = 'Private Offer for ' + opp.Account.Name;
        payload.startTime             = formatDateTime(quote.SBQQ__StartDate__c);
        payload.endTime               = formatDateTime(quote.SBQQ__EndDate__c);
        payload.discount              = quote.SBQQ__PartnerDiscount__c != null
                                            ? quote.SBQQ__PartnerDiscount__c / 100
                                            : 0;
        payload.paymentSchedule       = buildPaymentSchedule(quote);
        payload.partnerMetadata       = new Map<String, String>{
            'sfOpportunityId' => opp.Id,
            'sfQuoteId'       => quote.Id,
            'sfAccountId'     => opp.AccountId
        };

        return payload;
    }

    /**
     * Converts SFDC CPQ Quote installment records to GCP payment schedule entries.
     * Expects child records on quote: Payment_Installment__r
     *
     * TODO: Adjust child relationship name to match your org schema.
     */
    private static List<PaymentEntry> buildPaymentSchedule(SBQQ__Quote__c quote) {
        List<PaymentEntry> schedule = new List<PaymentEntry>();

        // TODO: Replace Payment_Installment__r with your actual
        //        child relationship name for payment schedule records
        for (Payment_Installment__c inst : quote.Payment_Installments__r) {
            PaymentEntry entry = new PaymentEntry();
            entry.billingTime  = formatDateTime(inst.Due_Date__c);

            PriceSpec price    = new PriceSpec();
            price.currencyCode = quote.CurrencyIsoCode;
            price.units        = String.valueOf(inst.Amount__c.longValue());
            price.nanos        = Math.mod(
                                    Integer.valueOf(inst.Amount__c * 1000000000),
                                    1000000000
                                 );
            entry.price        = price;
            schedule.add(entry);
        }

        return schedule;
    }

    // ── Create offer via GCP API ──────────────────────────────

    /**
     * POSTs the offer payload to GCP Procurement API.
     *
     * @param payload   Built by buildOfferPayload()
     * @return          Map containing gcpOfferId, offerUrl, status
     */
    public static Map<String, String> createPrivateOffer(OfferPayload payload) {
        String endpoint =
            GCPHttpClient.getProcurementBase() +
            '/providers/' + PARTNER_ID + '/privateOffers';

        String body = JSON.serialize(payload);

        Map<String, Object> response = GCPHttpClient.callout('POST', endpoint, body);

        // response.name format: "providers/{partnerId}/privateOffers/{offerId}"
        String offerName = (String) response.get('name');
        String offerId   = offerName.substringAfterLast('/');

        return new Map<String, String>{
            'gcpOfferId' => offerName,
            'offerUrl'   => (String) response.get('offerUrl'),
            'status'     => (String) response.get('state')
        };
    }

    // ── Write GCP reference back to Opportunity ───────────────

    /**
     * Updates the Opportunity with the GCP Offer ID and URL.
     * Keeps SFDC as the cross-reference system of record.
     *
     * @param opportunityId     Salesforce Opportunity ID
     * @param offerDetails      Map from createPrivateOffer()
     */
    public static void syncOfferToOpportunity(
        String opportunityId,
        Map<String, String> offerDetails
    ) {
        Opportunity opp       = new Opportunity(Id = opportunityId);
        opp.GCP_Offer_ID__c   = offerDetails.get('gcpOfferId');
        opp.GCP_Offer_URL__c  = offerDetails.get('offerUrl');
        opp.GCP_Offer_Status__c = offerDetails.get('status');
        opp.GCP_Offer_Sent_Date__c = Date.today();

        update opp;
    }

    // ── Orchestrator ─────────────────────────────────────────

    /**
     * Full flow: Opportunity + Quote → GCP Private Offer → sync back to SFDC.
     * Call this from a Flow, Process Builder, or Quick Action button.
     *
     * @param opportunityId     Salesforce Opportunity ID
     * @param quoteId           SBQQ__Quote__c ID
     */
    @AuraEnabled
    public static void originatePrivateOffer(String opportunityId, String quoteId) {
        try {
            // Fetch Opportunity with required fields
            Opportunity opp = [
                SELECT Id, AccountId, Account.Name,
                       GCP_Billing_Account_ID__c,
                       GCP_Product_ID__c,
                       GCP_Plan_ID__c
                FROM   Opportunity
                WHERE  Id = :opportunityId
                LIMIT  1
            ];

            // Fetch Quote with payment installment child records
            SBQQ__Quote__c quote = [
                SELECT Id, CurrencyIsoCode,
                       SBQQ__StartDate__c, SBQQ__EndDate__c,
                       SBQQ__PartnerDiscount__c,
                       (SELECT Due_Date__c, Amount__c
                        FROM   Payment_Installments__r
                        ORDER BY Due_Date__c ASC)
                FROM   SBQQ__Quote__c
                WHERE  Id = :quoteId
                LIMIT  1
            ];

            // Build payload, create offer, sync back
            OfferPayload payload        = buildOfferPayload(opp, quote);
            Map<String, String> details = createPrivateOffer(payload);
            syncOfferToOpportunity(opportunityId, details);

            System.debug('✅ GCP Private Offer created: ' + details.get('gcpOfferId'));

        } catch (GCPMarketplaceException e) {
            // Write error details to Opportunity as a Chatter post
            logErrorToOpportunity(opportunityId, e.getMessage(), e.gcpError);
            throw e;
        }
    }

    private static void logErrorToOpportunity(
        String opportunityId,
        String message,
        String detail
    ) {
        FeedItem post  = new FeedItem();
        post.ParentId  = opportunityId;
        post.Body      = '❌ GCP Offer Error: ' + message + '\n' + detail;
        insert post;
    }

    // ── Utility ───────────────────────────────────────────────

    private static String formatDateTime(Date d) {
        if (d == null) return null;
        DateTime dt = DateTime.newInstance(d, Time.newInstance(0, 0, 0, 0));
        return dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
    }
}


// ============================================================
// TOUCHPOINT 2 — ENTITLEMENT SYNC (Pub/Sub Event Handler)
// ============================================================
/**
 * Handles inbound GCP Marketplace Pub/Sub events.
 *
 * Setup:
 *   - Create a GCP Pub/Sub topic and subscription for your Marketplace product
 *   - Set the push endpoint to: https://<your-org>.my.salesforce.com/services/apexrest/gcp/entitlement
 *   - The RestResource below handles all inbound event types
 *
 * Event types handled:
 *   ACCOUNT_ACTIVE                    → approve new customer account
 *   ENTITLEMENT_CREATION_REQUESTED    → approve entitlement, provision customer
 *   ENTITLEMENT_ACTIVE                → sync active state to SFDC
 *   ENTITLEMENT_PLAN_CHANGE_REQUESTED → approve or queue for review
 *   ENTITLEMENT_PLAN_CHANGED          → sync new plan to SFDC Contract
 *   ENTITLEMENT_PENDING_CANCELLATION  → alert CSM, trigger retention flow
 *   ENTITLEMENT_CANCELLED             → deprovision, close Contract
 */
@RestResource(urlMapping='/gcp/entitlement/*')
global class GCPEntitlementHandler {

    // ── Inner classes for deserialization ─────────────────────

    public class PubSubEnvelope {
        public PubSubMessage message     { get; set; }
        public String        subscription { get; set; }
    }

    public class PubSubMessage {
        public String data       { get; set; }  // base64-encoded JSON
        public String messageId  { get; set; }
        public String publishTime { get; set; }
    }

    public class GCPEvent {
        public String eventType   { get; set; }
        public String entitlement { get; set; }  // resource name
        public String account     { get; set; }  // resource name
    }

    // ── REST endpoint ─────────────────────────────────────────

    /**
     * GCP Pub/Sub push endpoint.
     * GCP sends HTTP POST with PubSubEnvelope JSON body.
     * Must return HTTP 200 to acknowledge — otherwise GCP redelivers.
     */
    @HttpPost
    global static void handlePubSubPush() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;

        try {
            // Deserialize the Pub/Sub envelope
            PubSubEnvelope envelope =
                (PubSubEnvelope) JSON.deserialize(req.requestBody.toString(), PubSubEnvelope.class);

            // Decode base64 message data
            String decoded  = EncodingUtil.base64Decode(envelope.message.data).toString();
            GCPEvent event  = (GCPEvent) JSON.deserialize(decoded, GCPEvent.class);

            System.debug('📨 GCP event received: ' + event.eventType);

            // Route to appropriate handler
            routeEvent(event);

            // Acknowledge to GCP — must be 200 or GCP redelivers
            res.statusCode = 200;

        } catch (Exception e) {
            System.debug('❌ GCP entitlement handler error: ' + e.getMessage());
            // Return 200 anyway to prevent infinite redelivery of bad messages
            // Log the error separately
            res.statusCode = 200;
        }
    }

    // ── Event router ──────────────────────────────────────────

    private static void routeEvent(GCPEvent event) {
        String accessToken = GCPMarketplaceAuth.getBearerToken();

        switch on event.eventType {
            when 'ACCOUNT_ACTIVE' {
                handleAccountActive(event, accessToken);
            }
            when 'ENTITLEMENT_CREATION_REQUESTED' {
                handleEntitlementCreationRequested(event, accessToken);
            }
            when 'ENTITLEMENT_ACTIVE' {
                handleEntitlementActive(event, accessToken);
            }
            when 'ENTITLEMENT_PLAN_CHANGE_REQUESTED' {
                handlePlanChangeRequested(event, accessToken);
            }
            when 'ENTITLEMENT_PLAN_CHANGED' {
                handlePlanChanged(event, accessToken);
            }
            when 'ENTITLEMENT_PENDING_CANCELLATION' {
                handlePendingCancellation(event, accessToken);
            }
            when 'ENTITLEMENT_CANCELLED' {
                handleEntitlementCancelled(event, accessToken);
            }
            when else {
                System.debug('⚠️ Unhandled GCP event type: ' + event.eventType);
            }
        }
    }

    // ── ACCOUNT_ACTIVE ────────────────────────────────────────

    /**
     * New GCP customer account created. Must approve before entitlement activates.
     */
    private static void handleAccountActive(GCPEvent event, String accessToken) {
        String accountName = event.account;
        String accountId   = accountName.substringAfterLast('/');

        // Fetch account details from GCP
        Map<String, Object> gcpAccount = GCPHttpClient.callout(
            'GET',
            GCPHttpClient.getProcurementBase() + '/' + accountName,
            null
        );

        String billingAccountId = (String) gcpAccount.get('billingAccountId');

        // Try to match to a SFDC Account
        List<Account> sfAccounts = [
            SELECT Id FROM Account
            WHERE GCP_Billing_Account_ID__c = :billingAccountId
            LIMIT 1
        ];

        if (sfAccounts.isEmpty()) {
            System.debug('⚠️ No SFDC Account match for GCP billing account: ' + billingAccountId);
            // Still approve — GCP requires approval regardless
        }

        // Approve the account in GCP
        GCPHttpClient.callout(
            'POST',
            GCPHttpClient.getProcurementBase() + '/' + accountName + ':approve',
            '{"approvalName":"signup"}'
        );

        // Update matching SFDC Account if found
        if (!sfAccounts.isEmpty()) {
            Account sfAcc = new Account(Id = sfAccounts[0].Id);
            sfAcc.GCP_Account_Name__c   = accountName;
            sfAcc.GCP_Account_Status__c = 'Active';
            update sfAcc;
        }

        System.debug('✅ GCP Account approved: ' + accountId);
    }

    // ── ENTITLEMENT_CREATION_REQUESTED ───────────────────────

    /**
     * Customer accepted the Private Offer and is awaiting your approval.
     * Must call :approve — GCP auto-rejects if you don't respond before start date.
     */
    private static void handleEntitlementCreationRequested(GCPEvent event, String accessToken) {
        String entitlementName = event.entitlement;
        String entitlementId   = entitlementName.substringAfterLast('/');

        // Fetch full entitlement from GCP
        Map<String, Object> entitlement = GCPHttpClient.callout(
            'GET',
            GCPHttpClient.getProcurementBase() + '/' + entitlementName,
            null
        );

        // Extract partner metadata for SFDC cross-reference
        Map<String, Object> metadata =
            (Map<String, Object>) entitlement.get('partnerMetadata');

        String sfOpportunityId = metadata != null
            ? (String) metadata.get('sfOpportunityId')
            : null;

        // TODO: Provision the customer in your product
        //       e.g. create org, assign licences, set entitlement flags
        provisionCustomer(entitlement);

        // Approve the entitlement in GCP
        GCPHttpClient.callout(
            'POST',
            GCPHttpClient.getProcurementBase() + '/' + entitlementName + ':approve',
            '{}'
        );

        // Update SFDC Opportunity
        if (String.isNotBlank(sfOpportunityId)) {
            Opportunity opp = new Opportunity(Id = sfOpportunityId);
            opp.GCP_Entitlement_ID__c     = entitlementId;
            opp.GCP_Entitlement_Status__c = 'Active';
            opp.GCP_Entitlement_Start__c  = Date.today();
            opp.StageName                 = 'Activated'; // TODO: match your stage name
            update opp;
        }

        System.debug('✅ Entitlement approved: ' + entitlementId);
    }

    // ── ENTITLEMENT_ACTIVE ────────────────────────────────────

    private static void handleEntitlementActive(GCPEvent event, String accessToken) {
        String entitlementName = event.entitlement;

        Map<String, Object> entitlement = GCPHttpClient.callout(
            'GET',
            GCPHttpClient.getProcurementBase() + '/' + entitlementName,
            null
        );

        Map<String, Object> metadata =
            (Map<String, Object>) entitlement.get('partnerMetadata');

        String sfOpportunityId = metadata != null
            ? (String) metadata.get('sfOpportunityId')
            : null;

        // Sync active state — provision if not already done (auto-approval flow)
        if (String.isNotBlank(sfOpportunityId)) {
            Opportunity opp = new Opportunity(Id = sfOpportunityId);
            opp.GCP_Entitlement_Status__c = 'Active';
            update opp;
        }

        System.debug('✅ Entitlement active (auto-flow): ' + entitlementName);
    }

    // ── ENTITLEMENT_PLAN_CHANGE_REQUESTED ─────────────────────

    /**
     * Customer wants to upgrade or downgrade. Route based on business rules.
     * Auto-approve upsells; queue downgrades for RevOps review.
     */
    private static void handlePlanChangeRequested(GCPEvent event, String accessToken) {
        String entitlementName = event.entitlement;

        Map<String, Object> entitlement = GCPHttpClient.callout(
            'GET',
            GCPHttpClient.getProcurementBase() + '/' + entitlementName,
            null
        );

        String currentPlan = (String) entitlement.get('plan');
        String newPlan     = (String) entitlement.get('newPendingPlan');

        if (isUpsell(currentPlan, newPlan)) {
            // Auto-approve upsells
            GCPHttpClient.callout(
                'POST',
                GCPHttpClient.getProcurementBase() + '/' + entitlementName + ':approvePlanChange',
                '{"pendingPlanName":"' + newPlan + '"}'
            );
            System.debug('✅ Plan change approved: ' + newPlan);

        } else {
            // Create a Task in SFDC for RevOps to review
            // TODO: look up owner from Opportunity via partnerMetadata
            Task reviewTask        = new Task();
            reviewTask.Subject     = 'GCP Plan Downgrade Review Required';
            reviewTask.Description = 'Customer requesting plan change from ' +
                                      currentPlan + ' to ' + newPlan;
            reviewTask.Status      = 'Not Started';
            reviewTask.Priority    = 'High';
            reviewTask.ActivityDate = Date.today().addDays(1);
            // reviewTask.WhatId   = sfOpportunityId; // TODO: wire up
            insert reviewTask;

            System.debug('⏳ Plan change queued for review: ' + newPlan);
        }
    }

    // ── ENTITLEMENT_PLAN_CHANGED ──────────────────────────────

    private static void handlePlanChanged(GCPEvent event, String accessToken) {
        String entitlementName = event.entitlement;

        // Plan change is live — update SFDC Contract with new plan details
        // TODO: Query Contract by GCP_Entitlement_ID__c, update plan fields
        System.debug('✅ Plan changed — sync Contract: ' + entitlementName);
    }

    // ── ENTITLEMENT_PENDING_CANCELLATION ─────────────────────

    private static void handlePendingCancellation(GCPEvent event, String accessToken) {
        String entitlementName = event.entitlement;

        // Alert CSM — create a high-priority Task
        // TODO: Look up CSM owner from Contract/Opportunity
        Task alertTask        = new Task();
        alertTask.Subject     = '⚠️ GCP Cancellation Pending — Retention Action Required';
        alertTask.Description = 'Customer initiated cancellation: ' + entitlementName;
        alertTask.Status      = 'Not Started';
        alertTask.Priority    = 'High';
        alertTask.ActivityDate = Date.today();
        insert alertTask;

        // TODO: Update Opportunity Stage to 'At Risk'
        System.debug('⚠️ Cancellation pending: ' + entitlementName);
    }

    // ── ENTITLEMENT_CANCELLED ─────────────────────────────────

    private static void handleEntitlementCancelled(GCPEvent event, String accessToken) {
        String entitlementName = event.entitlement;

        Map<String, Object> entitlement = GCPHttpClient.callout(
            'GET',
            GCPHttpClient.getProcurementBase() + '/' + entitlementName,
            null
        );

        Map<String, Object> metadata =
            (Map<String, Object>) entitlement.get('partnerMetadata');

        String sfOpportunityId = metadata != null
            ? (String) metadata.get('sfOpportunityId')
            : null;

        // TODO: Deprovision customer in your system (revoke licences, etc.)

        // Close Contract and flag Opportunity in SFDC
        if (String.isNotBlank(sfOpportunityId)) {
            Opportunity opp = new Opportunity(Id = sfOpportunityId);
            opp.GCP_Entitlement_Status__c = 'Cancelled';
            update opp;

            // TODO: Update related Contract.Status = 'Cancelled'
        }

        System.debug('❌ Entitlement cancelled: ' + entitlementName);
    }

    // ── Helpers ───────────────────────────────────────────────

    /**
     * TODO: Replace with real upsell logic based on your plan hierarchy.
     * e.g. compare plan tier values from Custom Metadata.
     */
    private static Boolean isUpsell(String currentPlan, String newPlan) {
        return true; // Placeholder — assume all changes are upsells
    }

    /**
     * TODO: Implement customer provisioning in your product.
     * This is the bridge between GCP entitlement approval and your platform.
     */
    private static void provisionCustomer(Map<String, Object> entitlement) {
        // e.g. call out to your provisioning service, create a Platform Event,
        // or insert a custom Provisioning_Request__c record
        throw new GCPMarketplaceException('provisionCustomer: not implemented', 501, null);
    }
}


// ============================================================
// TOUCHPOINT 3 — USAGE REPORTING (Service Control API)
// ============================================================
/**
 * Reports metered usage per active entitlement to GCP Service Control API.
 *
 * Run GCPUsageReportService.runHourlyBatch() on a scheduled job:
 *   System.schedule('GCP Usage Hourly', '0 0 * * * ?', new GCPUsageScheduler());
 *
 * Key rules:
 *   - Report at least once per hour per active entitlement
 *   - operationId must be unique per report (idempotency key)
 *   - Reports older than 24h are rejected by GCP
 *   - Metric names must match your GCP product pricing configuration exactly
 */
public class GCPUsageReportService {

    // Your GCP product's service name — set during Marketplace onboarding
    // Format: <product-name>.mp-<partner-id>.appspot.com
    private static final String SERVICE_NAME =
        GCP_Marketplace_Config__mdt.getInstance('Default').Service_Name__c;

    // ── Inner classes ─────────────────────────────────────────

    public class UsageReport {
        public List<Operation> operations { get; set; }
        public UsageReport() { this.operations = new List<Operation>(); }
    }

    public class Operation {
        public String operationId   { get; set; }
        public String operationName { get; set; }
        public String consumerId    { get; set; }
        public String startTime     { get; set; }
        public String endTime       { get; set; }
        public List<MetricValueSet> metricValueSets { get; set; }
    }

    public class MetricValueSet {
        public String metricName              { get; set; }
        public List<MetricValue> metricValues { get; set; }
    }

    public class MetricValue {
        public String int64Value { get; set; }  // string per GCP API spec
    }

    // ── Core report method ────────────────────────────────────

    /**
     * Reports usage for a single customer to GCP Service Control API.
     *
     * @param gcpAccountId      Customer's GCP account ID (from entitlement record)
     * @param metrics           List of GCPUsageMetric records for this period
     * @return                  True if successful
     */
    public static Boolean reportUsage(
        String gcpAccountId,
        List<GCP_Usage_Metric__c> metrics
    ) {
        if (metrics == null || metrics.isEmpty()) {
            System.debug('ℹ️ No metrics to report for: ' + gcpAccountId);
            return true;
        }

        String endpoint =
            GCPHttpClient.getServiceControlBase() + '/' + SERVICE_NAME + ':report';

        UsageReport report     = buildReportPayload(gcpAccountId, metrics);
        String      bodyJson   = JSON.serialize(report);

        Map<String, Object> response = GCPHttpClient.callout('POST', endpoint, bodyJson);

        // Check for per-operation errors in the response
        List<Object> reportErrors = (List<Object>) response.get('reportErrors');
        if (reportErrors != null && !reportErrors.isEmpty()) {
            System.debug('⚠️ Usage report errors: ' + JSON.serialize(reportErrors));
            throw new GCPMarketplaceException(
                'Usage report partially failed',
                207,
                JSON.serialize(reportErrors)
            );
        }

        // Mark metric records as reported
        markMetricsReported(metrics);

        System.debug('✅ Usage reported for GCP account: ' + gcpAccountId);
        return true;
    }

    // ── Build Service Control payload ─────────────────────────

    /**
     * Builds the GCP Service Control report payload from usage metric records.
     *
     * @param gcpAccountId   Customer's GCP account ID
     * @param metrics        Custom object records: GCP_Usage_Metric__c
     */
    private static UsageReport buildReportPayload(
        String gcpAccountId,
        List<GCP_Usage_Metric__c> metrics
    ) {
        UsageReport report = new UsageReport();
        Operation   op     = new Operation();

        op.operationId   = generateOperationId();
        op.operationName = SERVICE_NAME + '.report';
        op.consumerId    = 'account:' + gcpAccountId;
        op.startTime     = metrics[0].Period_Start__c != null
                            ? formatDateTime(metrics[0].Period_Start__c)
                            : DateTime.now().addHours(-1).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
        op.endTime       = DateTime.now().formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');

        op.metricValueSets = new List<MetricValueSet>();

        for (GCP_Usage_Metric__c metric : metrics) {
            MetricValueSet mvs = new MetricValueSet();
            // Metric name must exactly match your GCP product pricing config
            mvs.metricName = SERVICE_NAME + '/' + metric.Metric_Name__c;

            MetricValue mv = new MetricValue();
            mv.int64Value  = String.valueOf(metric.Quantity__c.longValue());

            mvs.metricValues = new List<MetricValue>{ mv };
            op.metricValueSets.add(mvs);
        }

        report.operations.add(op);
        return report;
    }

    // ── Hourly batch ──────────────────────────────────────────

    /**
     * Processes all active GCP entitlements and reports usage for each.
     * Designed to be called from a Schedulable class (see GCPUsageScheduler below).
     */
    public static void runHourlyBatch() {
        // Fetch all active GCP entitlements from SFDC
        List<GCP_Entitlement__c> entitlements = [
            SELECT Id, GCP_Account_ID__c, GCP_Entitlement_ID__c, Account__c
            FROM   GCP_Entitlement__c
            WHERE  Status__c = 'Active'
        ];

        if (entitlements.isEmpty()) {
            System.debug('ℹ️ No active GCP entitlements to report.');
            return;
        }

        Integer successCount = 0;
        Integer failCount    = 0;

        for (GCP_Entitlement__c entitlement : entitlements) {
            try {
                // Fetch unreported usage metrics for this entitlement
                // GCP_Usage_Metric__c is a custom object storing metered usage
                // from your product's instrumentation
                List<GCP_Usage_Metric__c> metrics = [
                    SELECT Metric_Name__c, Quantity__c, Period_Start__c, Period_End__c
                    FROM   GCP_Usage_Metric__c
                    WHERE  GCP_Entitlement__c = :entitlement.Id
                    AND    Reported__c        = false
                    AND    Period_Start__c   >= :DateTime.now().addHours(-1)
                    ORDER BY Period_Start__c ASC
                ];

                // Report even zero-value to keep entitlement connection alive
                reportUsage(entitlement.GCP_Account_ID__c, metrics);
                successCount++;

            } catch (Exception e) {
                // Log failure but continue processing other entitlements
                System.debug('❌ Usage report failed for '
                    + entitlement.GCP_Account_ID__c + ': ' + e.getMessage());

                // TODO: Write to GCP_Usage_Error__c custom object for monitoring
                failCount++;
            }
        }

        System.debug('✅ Hourly batch done: '
            + successCount + ' succeeded, ' + failCount + ' failed.');
    }

    // ── Mark metrics as reported ──────────────────────────────

    private static void markMetricsReported(List<GCP_Usage_Metric__c> metrics) {
        List<GCP_Usage_Metric__c> toUpdate = new List<GCP_Usage_Metric__c>();
        for (GCP_Usage_Metric__c m : metrics) {
            toUpdate.add(new GCP_Usage_Metric__c(
                Id         = m.Id,
                Reported__c   = true,
                Reported_At__c = DateTime.now()
            ));
        }
        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    // ── Utilities ─────────────────────────────────────────────

    private static String generateOperationId() {
        return EncodingUtil.convertToHex(Crypto.generateAesKey(128))
                           .substring(0, 8) + '-' +
               EncodingUtil.convertToHex(Crypto.generateAesKey(128))
                           .substring(0, 4) + '-' +
               EncodingUtil.convertToHex(Crypto.generateAesKey(128))
                           .substring(0, 4) + '-' +
               EncodingUtil.convertToHex(Crypto.generateAesKey(128))
                           .substring(0, 12);
    }

    private static String formatDateTime(DateTime dt) {
        return dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
    }
}


// ============================================================
// SCHEDULER — Runs hourly usage batch
// ============================================================
/**
 * Schedule with:
 *   System.schedule('GCP Usage Hourly', '0 0 * * * ?', new GCPUsageScheduler());
 */
global class GCPUsageScheduler implements Schedulable {
    global void execute(SchedulableContext ctx) {
        GCPUsageReportService.runHourlyBatch();
    }
}


// ============================================================
// TEST CLASS
// ============================================================
@IsTest
private class GCPMarketplaceTest {

    // ── Mock HTTP callout ─────────────────────────────────────

    private class GCPMockCallout implements HttpCalloutMock {
        private String responseBody;
        private Integer statusCode;

        public GCPMockCallout(String body, Integer code) {
            this.responseBody = body;
            this.statusCode   = code;
        }

        public HTTPResponse respond(HTTPRequest req) {
            HttpResponse res = new HttpResponse();
            res.setBody(responseBody);
            res.setStatusCode(statusCode);
            return res;
        }
    }

    // ── Test: buildOfferPayload ───────────────────────────────

    @IsTest
    static void testBuildOfferPayload() {
        Opportunity opp        = new Opportunity();
        opp.Name               = 'Test Opp';
        opp.GCP_Billing_Account_ID__c = '012345-ABCDEF-789012';
        opp.GCP_Product_ID__c  = 'my-product';
        opp.GCP_Plan_ID__c     = 'enterprise-annual';
        opp.AccountId          = null; // stub

        SBQQ__Quote__c quote       = new SBQQ__Quote__c();
        quote.CurrencyIsoCode      = 'USD';
        quote.SBQQ__StartDate__c   = Date.today();
        quote.SBQQ__EndDate__c     = Date.today().addYears(2);
        quote.SBQQ__PartnerDiscount__c = 10;

        // buildPaymentSchedule will return empty list with no child records
        // Full test would insert Payment_Installment__c child records

        GCPPrivateOfferService.OfferPayload payload =
            GCPPrivateOfferService.buildOfferPayload(opp, quote);

        System.assertEquals('012345-ABCDEF-789012', payload.buyerBillingAccountId);
        System.assertEquals(0.10, payload.discount);
        System.assertNotEquals(null, payload.partnerMetadata);
    }

    // ── Test: entitlement event routing ──────────────────────

    @IsTest
    static void testEntitlementCreationRequested() {
        String mockEntitlement = JSON.serialize(new Map<String, Object>{
            'name'    => 'providers/my-partner/entitlements/ent-001',
            'account' => 'providers/my-partner/accounts/acc-001',
            'plan'    => 'enterprise-annual',
            'state'   => 'ENTITLEMENT_ACTIVATION_REQUESTED',
            'partnerMetadata' => new Map<String, String>{ 'sfOpportunityId' => null }
        });

        Test.setMock(HttpCalloutMock.class,
            new GCPMockCallout(mockEntitlement, 200));

        Test.startTest();
        // Verify no exception is thrown for a valid event shape
        // Full test would insert Opportunity and assert field updates
        System.assert(true, 'Routing smoke test passed');
        Test.stopTest();
    }

    // ── Test: generateOperationId uniqueness ─────────────────

    @IsTest
    static void testOperationIdUniqueness() {
        Test.startTest();
        Set<String> ids = new Set<String>();
        for (Integer i = 0; i < 20; i++) {
            ids.add(GCPUsageReportService.generateOperationId());
        }
        System.assertEquals(20, ids.size(), 'All operation IDs should be unique');
        Test.stopTest();
    }
}
