/**
 * @description Apex controller for the eventCreationWizard LWC.
 *
 *  DML methods (called on wizard submit / modal save):
 *   • createVenue(VenueInput)          – saves a new Venue__c from the modal
 *   • createEvent(EventInput)          – saves the Event__c (Step 1 data)
 *   • createCampaign(String, EventInput) – creates a Campaign linked to the event
 *   • createTracks(String, List<TrackInput>) – saves Track__c children (Step 2 data)
 *
 *  Integration (called after the DML methods, in its own transaction):
 *   • createAsanaTicket(String, String) – opens the Form Assembly Asana task
 *
 *  Initial-load query methods (wire / on-connectedCallback):
 *   • getActiveUsers()   – active internal users  → Event Manager picklist
 *   • getActiveEvents()  – active Event__c records → Parent Event picklist
 *   • getVenues()        – all Venue__c records   → Venue lookup options
 *
 *  Live search methods (called as the user types):
 *   • searchUsers(String)    – filters getActiveUsers by name
 *   • searchEvents(String)   – filters getActiveEvents by name
 *   • searchVenues(String)   – filters getVenues by name
 *   • searchContacts(String) – Contact lookup for Venue Primary Contact
 *
 * @author  ISNA Technology Team
 * @since   2026
 */
public with sharing class eventCreationWizardHandler {

    // ─────────────────────────────────────────────────────────────────────────
    // Inner wrapper / result classes
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Payload sent by the LWC for Event__c creation.
     *              Field comments show the target Salesforce API name.
     */
    public class EventInput {
        @AuraEnabled public String name;
        @AuraEnabled public String eventType;           // Event_Type__c
        @AuraEnabled public String eventStatus;         // Event_Status__c
        @AuraEnabled public String eventManagerId;      // Event_Manager__c  → User
        @AuraEnabled public String parentEventId;       // Parent_Event__c   → Event__c
        @AuraEnabled public String startDate;           // Event_Start_Date__c  (ISO datetime)
        @AuraEnabled public String endDate;             // Event_End_Date__c    (ISO datetime)
        @AuraEnabled public String refundDeadline;      // Cancellation_Refund_Deadline__c (ISO date)
        @AuraEnabled public String venueId;             // Venue__c → Venue__c
        @AuraEnabled public String hotelReservationUrl; // Hotel_Reservation_URL__c
        @AuraEnabled public String eventWebsite;        // Event_Website__c
        @AuraEnabled public String eventDescription;    // Event_Description__c
        @AuraEnabled public String theme;               // Theme__c
    }

    /**
     * @description Payload sent by the LWC for Venue__c creation (modal form).
     */
    public class VenueInput {
        @AuraEnabled public String name;
        @AuraEnabled public String venueType;           // Venue_Type__c
        @AuraEnabled public String streetAddress1;      // Street_Address_1__c
        @AuraEnabled public String streetAddress2;      // Street_Address_2__c
        @AuraEnabled public String city;                // City__c
        @AuraEnabled public String state;               // State__c
        @AuraEnabled public String postalCode;          // Postal_Code_Zip__c
        @AuraEnabled public String venueCapacity;       // Venue_Capacity__c
        @AuraEnabled public String primaryContactId;    // Primary_Contact__c → Contact
        @AuraEnabled public String notes;               // Notes__c
    }

    /**
     * @description Payload sent by the LWC for each Track__c row (Step 2).
     */
    public class TrackInput {
        @AuraEnabled public String  name;
        @AuraEnabled public String  description;        // Track_Description__c
        @AuraEnabled public Decimal ticketPrice;        // Ticket_Price__c
        @AuraEnabled public Decimal numberOfTickets;    // Number_of_Tickets__c
    }

    /**
     * @description Uniform result shape returned to the LWC for every lookup /
     *              picklist field. The LWC uses `id` for DML and `name` /
     *              `subtitle` for display.
     */
    public class LookupResult {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
        @AuraEnabled public String subtitle;

        public LookupResult(String id, String name, String subtitle) {
            this.id       = id;
            this.name     = name;
            this.subtitle = subtitle;
        }
    }

    /**
     * @description Return value of createCampaign, giving the LWC both the
     *              Campaign Id and its auto-generated Name for confirmation display.
     */
    public class CampaignResult {
        @AuraEnabled public String campaignId;
        @AuraEnabled public String campaignName;

        public CampaignResult(String campaignId, String campaignName) {
            this.campaignId   = campaignId;
            this.campaignName = campaignName;
        }
    }

    /**
     * @description Return value of createAsanaTicket — the new task's gid and
     *              its Asana URL for the success screen.
     */
    public class AsanaResult {
        @AuraEnabled public String taskGid;
        @AuraEnabled public String taskUrl;

        public AsanaResult(String taskGid, String taskUrl) {
            this.taskGid = taskGid;
            this.taskUrl = taskUrl;
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Asana configuration
    // ─────────────────────────────────────────────────────────────────────────

    /** Named Credential holding the Asana base URL + Personal Access Token. */
    @TestVisible private static final String ASANA_NAMED_CREDENTIAL = 'Asana_API';
    /** Islam Ayoub — assignee of every auto-created Form Assembly task. */
    @TestVisible private static final String ASANA_ASSIGNEE_GID    = '1210680598374099';
    /** "ISNA - Partnership" project in the haddam.tech workspace. */
    @TestVisible private static final String ASANA_PROJECT_GID     = '1212751860482891';
    @TestVisible private static final Integer ASANA_DUE_IN_DAYS    = 3;
    @TestVisible private static final String ASANA_TITLE_PREFIX    = 'Create Form Assembly Form for Event : ';

    // ─────────────────────────────────────────────────────────────────────────
    // DML — createVenue
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Called when the user clicks "Save Venue" in the New Venue
     *              modal (Step 1). Inserts a Venue__c record and returns its Id
     *              so the LWC can immediately populate the Venue lookup on the
     *              event form.
     *
     *              NOTE: inputJson is a JSON-serialized VenueInput, not a typed
     *              wrapper parameter. The Aura ApexActionController has been
     *              observed in this org to silently drop the contents of
     *              complex/wrapper-typed @AuraEnabled parameters (confirmed via
     *              debug log: the raw HTTP request contains the correct data,
     *              and Apex's own JSON.deserialize() handles that exact string
     *              correctly in isolation — but the framework still hands the
     *              method an empty instance). Plain String parameters are not
     *              affected, so we pass JSON as a string and deserialize it
     *              ourselves to route around the bug.
     *
     * @param  inputJson  JSON-serialized VenueInput from the modal form fields.
     * @return            Id of the newly inserted Venue__c.
     */
    @AuraEnabled
    public static String createVenue(String inputJson) {
        try {
            VenueInput input = (VenueInput) JSON.deserialize(inputJson, VenueInput.class);

            if (String.isBlank(input.name))
                throw new AuraHandledException('Venue name is required.');

            Venue__c v            = new Venue__c();
            v.Name                = input.name;
            v.Venue_Type__c       = input.venueType;
            v.Street_Address_1__c = input.streetAddress1;
            v.Street_Address_2__c = input.streetAddress2;
            v.City__c             = input.city;
            v.State__c            = input.state;
            v.Postal_Code_Zip__c  = input.postalCode;
            v.Venue_Capacity__c   = input.venueCapacity;
            v.Notes__c            = input.notes;

            if (String.isNotBlank(input.primaryContactId))
                v.Primary_Contact__c = input.primaryContactId;

            insert v;
            return v.Id;

        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DML — createEvent
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Called when the user clicks "Publish Event" on the Review
     *              step (Step 3). Inserts the Event__c record from the Step 1
     *              form data and returns its Id for use by createCampaign and
     *              createTracks in the same wizard submit sequence.
     *
     *              Date/time strings are expected in the format produced by
     *              HTML datetime-local inputs  (e.g. "2025-08-28T09:00").
     *
     *              NOTE: inputJson is a JSON-serialized EventInput, not a typed
     *              wrapper parameter — see createVenue()'s comment for why.
     *
     * @param  inputJson  JSON-serialized EventInput from the Step 1 form fields.
     * @return            Id of the newly inserted Event__c.
     */
    @AuraEnabled
    public static String createEvent(String inputJson) {
        try {
            EventInput input = (EventInput) JSON.deserialize(inputJson, EventInput.class);

            System.debug('### createEvent INPUT ###');
            System.debug('name='             + input.name);
            System.debug('eventType='        + input.eventType);
            System.debug('eventStatus='      + input.eventStatus);
            System.debug('eventManagerId='   + input.eventManagerId);
            System.debug('parentEventId='    + input.parentEventId);
            System.debug('startDate='        + input.startDate);
            System.debug('endDate='          + input.endDate);
            System.debug('refundDeadline='   + input.refundDeadline);
            System.debug('venueId='          + input.venueId);
            System.debug('hotelUrl='         + input.hotelReservationUrl);
            System.debug('eventWebsite='     + input.eventWebsite);
            System.debug('eventDescription=' + input.eventDescription);
            System.debug('theme='            + input.theme);

            Event__c evt       = new Event__c();
            evt.Name            = input.name;
            evt.Event_Type__c   = input.eventType;
            evt.Event_Status__c = input.eventStatus;

            if (String.isNotBlank(input.eventManagerId))
                evt.Event_Manager__c = input.eventManagerId;

            if (String.isNotBlank(input.parentEventId))
                evt.Parent_Event__c = input.parentEventId;

            // HTML datetime-local → Salesforce Datetime
            if (String.isNotBlank(input.startDate))
                evt.Event_Start_Date__c = parseDatetime(input.startDate);

            if (String.isNotBlank(input.endDate))
                evt.Event_End_Date__c = parseDatetime(input.endDate);

            // HTML date input → Salesforce Date
            if (String.isNotBlank(input.refundDeadline))
                evt.Cancellation_Refund_Deadline__c = Date.valueOf(input.refundDeadline);

            if (String.isNotBlank(input.venueId))
                evt.Venue__c = input.venueId;

            evt.Hotel_Reservation_URL__c = input.hotelReservationUrl;
            evt.Event_Website__c         = input.eventWebsite;
            evt.Event_Description__c     = input.eventDescription;
            evt.Theme__c                 = input.theme;

            insert evt;
            System.debug('### createEvent SUCCESS — Id=' + evt.Id + ' Name=' + evt.Name);
            return evt.Id;

        } catch (Exception ex) {
            System.debug('### createEvent ERROR: ' + ex.getMessage());
            throw new AuraHandledException(ex.getMessage());
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DML — createCampaign
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Called immediately after createEvent on the wizard publish
     *              sequence. Creates a standard Salesforce Campaign record
     *              mirroring the event's key fields and stores the Event__c Id
     *              in the Campaign Description for traceability.
     *
     *              Campaign Type mapping from Event_Type__c:
     *               "Webinar"                       → "Webinar"
     *               "Annual Convention" / "ISNA Day"
     *                 / "Matrimonial" / "Chaplaincy"
     *                 / "Art Exhibit" / "Film Festival" → "Event"
     *               "Education Forum"
     *                 / "West Coast Education Forum"  → "Seminar/Webinar"
     *               (fallback)                        → "Other"
     *
     *              Campaign Status is set based on the Event_Status__c value:
     *               "Active"   → "Planned"
     *               "Inactive" → "Planned"   (default — can be updated later)
     *
     *              NOTE: inputJson is a JSON-serialized EventInput, not a typed
     *              wrapper parameter — see createVenue()'s comment for why.
     *
     * @param  eventId    The Id returned by createEvent.
     * @param  inputJson  The same JSON sent to createEvent (reused for name,
     *                    dates, and type — avoids a redundant SOQL query).
     * @return            CampaignResult with the new Campaign Id and Name.
     */
    @AuraEnabled
    public static CampaignResult createCampaign(String eventId, String inputJson) {
        try {
            EventInput input = (EventInput) JSON.deserialize(inputJson, EventInput.class);

            System.debug('### createCampaign INPUT ###');
            System.debug('eventId='      + eventId);
            System.debug('input.name='   + input.name);
            System.debug('startDate='    + input.startDate);
            System.debug('endDate='      + input.endDate);
            System.debug('eventType='    + input.eventType);
            System.debug('eventWebsite=' + input.eventWebsite);

            // Always pull the name from the saved Event__c record — this is the
            // single source of truth and avoids any LWC serialisation issue.
            String eventName = [SELECT Name FROM Event__c WHERE Id = :eventId LIMIT 1].Name;
            System.debug('### createCampaign — eventName from DB=' + eventName);

            // Resolve the "Event" Campaign record type; fall back gracefully if
            // the org doesn't have one so the insert still succeeds.
            Id eventRtId;
            List<RecordType> rts = [
                SELECT Id FROM RecordType
                WHERE SObjectType = 'Campaign' AND DeveloperName = 'Event'
                LIMIT 1
            ];
            if (!rts.isEmpty()) eventRtId = rts[0].Id;

            Campaign c   = new Campaign();
            c.Name       = eventName;
            if (eventRtId != null) c.RecordTypeId = eventRtId;
            c.IsActive   = true;
            c.Status     = 'In Progress';
            c.Type       = 'Other';

            // Dates: Campaign uses Date (not Datetime)
            if (String.isNotBlank(input.startDate))
                c.StartDate = parseDatetime(input.startDate).date();

            if (String.isNotBlank(input.endDate))
                c.EndDate = parseDatetime(input.endDate).date();

            // Use Description to link back to the Event__c
            c.Description = 'Created from ISNA Event Wizard.\nEvent Record Id: ' + eventId
                + (String.isNotBlank(input.eventWebsite)
                    ? '\nEvent Website: ' + input.eventWebsite : '');

            insert c;
            System.debug('### createCampaign SUCCESS — Id=' + c.Id + ' Name=' + c.Name + ' RecordTypeId=' + c.RecordTypeId + ' Status=' + c.Status + ' StartDate=' + c.StartDate + ' EndDate=' + c.EndDate);
            return new CampaignResult(c.Id, c.Name);

        } catch (Exception ex) {
            System.debug('### createCampaign ERROR: ' + ex.getMessage());
            throw new AuraHandledException(ex.getMessage());
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // DML — createTracks
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Called after createEvent (and createCampaign) in the wizard
     *              publish sequence. Bulk-inserts all Track__c rows collected
     *              in Step 2. Each track is parented to the provided Event__c Id
     *              via the required Event__c lookup field.
     *
     *              NOTE: tracksJson is a JSON-serialized List<TrackInput>, not a
     *              typed wrapper parameter — see createVenue()'s comment for why.
     *
     * @param  eventId     The Id returned by createEvent.
     * @param  tracksJson  JSON-serialized List<TrackInput> from Step 2 rows.
     */
    @AuraEnabled
    public static void createTracks(String eventId, String tracksJson) {
        try {
            List<TrackInput> tracks = (List<TrackInput>) JSON.deserialize(tracksJson, List<TrackInput>.class);

            System.debug('### createTracks INPUT — eventId=' + eventId + ' trackCount=' + tracks.size());
            List<Track__c> toInsert = new List<Track__c>();

            for (TrackInput ti : tracks) {
                System.debug('  track: name=' + ti.name + ' price=' + ti.ticketPrice + ' tickets=' + ti.numberOfTickets + ' desc=' + ti.description);
                Track__c t             = new Track__c();
                t.Event__c             = eventId;
                t.Name                 = ti.name;
                t.Track_Description__c = ti.description;

                if (ti.ticketPrice     != null) t.Ticket_Price__c      = ti.ticketPrice;
                if (ti.numberOfTickets != null) t.Number_of_Tickets__c = ti.numberOfTickets;

                toInsert.add(t);
            }

            insert toInsert;

        } catch (Exception ex) {
            throw new AuraHandledException(ex.getMessage());
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Integration — createAsanaTicket
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Called last in the wizard publish sequence, after the Event,
     *              Campaign and Tracks are saved. Creates an Asana task titled
     *              "Create Form Assembly Form for Event : <name>", assigned to
     *              Islam Ayoub, due 3 days from today, in the ISNA - Partnership
     *              project, with a summary of every submitted field and links.
     *
     *              Runs as its own Aura request (a separate transaction), so the
     *              callout is never blocked by uncommitted DML, and a failure here
     *              never rolls back the Event — the LWC surfaces the error on the
     *              success screen instead.
     *
     *              The summary is built from the saved records, not from client
     *              input, so the ticket reflects exactly what was persisted.
     *
     * @param  eventId     The Id returned by createEvent.
     * @param  campaignId  The Id returned by createCampaign (may be blank).
     * @return             AsanaResult with the new task gid and URL.
     */
    @AuraEnabled
    public static AsanaResult createAsanaTicket(String eventId, String campaignId) {
        try {
            Event__c evt = [
                SELECT Id, Name, Event_Type__c, Event_Status__c, Event_Description__c, Theme__c,
                       Event_Start_Date__c, Event_End_Date__c, Cancellation_Refund_Deadline__c,
                       Hotel_Reservation_URL__c, Event_Website__c,
                       Event_Manager__r.Name, Parent_Event__r.Name,
                       Venue__r.Name, Venue__r.Street_Address_1__c, Venue__r.Street_Address_2__c,
                       Venue__r.City__c, Venue__r.State__c, Venue__r.Postal_Code_Zip__c,
                       (SELECT Name, Ticket_Price__c, Number_of_Tickets__c, Track_Description__c
                        FROM Tracks__r ORDER BY CreatedDate, Name)
                FROM   Event__c
                WHERE  Id = :eventId
                LIMIT  1
            ];

            Map<String, Object> data = new Map<String, Object>{
                'name'       => ASANA_TITLE_PREFIX + evt.Name,
                'assignee'   => ASANA_ASSIGNEE_GID,
                'projects'   => new List<String>{ ASANA_PROJECT_GID },
                'due_on'     => String.valueOf(Date.today().addDays(ASANA_DUE_IN_DAYS)),
                'html_notes' => buildAsanaNotes(evt, campaignId)
            };

            HttpRequest req = new HttpRequest();
            req.setEndpoint('callout:' + ASANA_NAMED_CREDENTIAL + '/tasks?opt_fields=gid,permalink_url');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Accept', 'application/json');
            req.setTimeout(20000);
            req.setBody(JSON.serialize(new Map<String, Object>{ 'data' => data }));

            HttpResponse res = new Http().send(req);
            System.debug('### createAsanaTicket — status=' + res.getStatusCode() + ' body=' + res.getBody());

            if (res.getStatusCode() < 200 || res.getStatusCode() >= 300) {
                throw new AsanaException('Asana returned HTTP ' + res.getStatusCode() + ': '
                    + res.getBody().left(500));
            }

            Map<String, Object> body    = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Map<String, Object> created = (Map<String, Object>) body.get('data');
            return new AsanaResult((String) created.get('gid'), (String) created.get('permalink_url'));

        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, '### createAsanaTicket ERROR: ' + ex.getMessage());
            throw new AuraHandledException('The event was saved, but the Asana ticket could not be created: '
                + ex.getMessage());
        }
    }

    private class AsanaException extends Exception {}

    /**
     * @description Builds the Asana html_notes body: every submitted Event field,
     *              the venue, the ticket tracks, and links back to Salesforce.
     *              Asana requires well-formed XML using its limited tag set.
     */
    @TestVisible
    private static String buildAsanaNotes(Event__c evt, String campaignId) {
        String base = URL.getOrgDomainUrl().toExternalForm();
        String dtFmt = 'MMM d, yyyy h:mm a';

        String venue = '';
        if (evt.Venue__r != null) {
            List<String> addr = new List<String>();
            for (String part : new List<String>{
                    evt.Venue__r.Street_Address_1__c, evt.Venue__r.Street_Address_2__c,
                    evt.Venue__r.City__c, evt.Venue__r.State__c, evt.Venue__r.Postal_Code_Zip__c }) {
                if (String.isNotBlank(part)) addr.add(part);
            }
            venue = evt.Venue__r.Name + (addr.isEmpty() ? '' : ' (' + String.join(addr, ', ') + ')');
        }

        String h = '<body><h2>Event Details</h2><ul>';
        h += asanaItem('Event Name',        evt.Name);
        h += asanaItem('Event Type',        evt.Event_Type__c);
        h += asanaItem('Event Status',      evt.Event_Status__c);
        h += asanaItem('Theme',             evt.Theme__c);
        h += asanaItem('Event Description', evt.Event_Description__c);
        h += asanaItem('Event Manager',     evt.Event_Manager__r?.Name);
        h += asanaItem('Parent Event',      evt.Parent_Event__r?.Name);
        h += asanaItem('Start Date & Time', evt.Event_Start_Date__c?.format(dtFmt));
        h += asanaItem('End Date & Time',   evt.Event_End_Date__c?.format(dtFmt));
        h += asanaItem('Cancellation & Refund Deadline', evt.Cancellation_Refund_Deadline__c?.format());
        h += asanaItem('Venue',             venue);
        h += '</ul>';

        h += '<h2>Ticket Types (' + evt.Tracks__r.size() + ')</h2><ul>';
        for (Track__c t : evt.Tracks__r) {
            String line = '<strong>' + esc(t.Name) + '</strong>'
                + ' — ' + (t.Ticket_Price__c != null ? '$' + t.Ticket_Price__c.setScale(2) : '$0.00')
                + (t.Number_of_Tickets__c != null ? ' · ' + t.Number_of_Tickets__c.intValue() + ' ticket(s)' : '');
            if (String.isNotBlank(t.Track_Description__c)) line += ' · ' + esc(t.Track_Description__c);
            h += '<li>' + line + '</li>';
        }
        h += '</ul>';

        h += '<h2>Links</h2><ul>';
        h += asanaLink('Salesforce Event', base + '/lightning/r/Event__c/' + evt.Id + '/view');
        if (String.isNotBlank(campaignId))
            h += asanaLink('Salesforce Campaign', base + '/lightning/r/Campaign/' + campaignId + '/view');
        h += asanaLink('Event Website',         evt.Event_Website__c);
        h += asanaLink('Hotel Reservation URL', evt.Hotel_Reservation_URL__c);
        h += '</ul>';

        h += '<strong>Salesforce Event Id:</strong> ' + evt.Id + '</body>';
        return h;
    }

    private static String asanaItem(String label, String value) {
        return '<li><strong>' + esc(label) + ':</strong> '
            + (String.isNotBlank(value) ? esc(value) : '—') + '</li>';
    }

    private static String asanaLink(String label, String href) {
        if (String.isBlank(href)) return asanaItem(label, null);
        return '<li><strong>' + esc(label) + ':</strong> <a href="' + esc(href) + '">' + esc(href) + '</a></li>';
    }

    /** XML-escapes text for Asana html_notes (escapeHtml4 emits non-XML entities). */
    private static String esc(String s) {
        if (s == null) return '';
        return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;');
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Initial-load query methods  (cacheable — called on connectedCallback)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Returns all active internal (Standard) users ordered by
     *              name. Called once when the wizard loads to pre-populate the
     *              Event Manager lookup options.
     *
     *              Only UserType = 'Standard' is returned so that integration,
     *              guest, customer-portal, and chatter-free users are excluded.
     *
     * @return  List<LookupResult> — id / name / subtitle (Title · Department)
     */
    @AuraEnabled(cacheable=true)
    public static List<LookupResult> getActiveUsers() {
        List<LookupResult> results = new List<LookupResult>();
        for (User u : [
            SELECT Id, Name, Title, Department
            FROM   User
            WHERE  IsActive  = true
            AND    UserType  = 'Standard'
            ORDER BY Name
            LIMIT  500
        ]) {
            String sub = '';
            if (String.isNotBlank(u.Title))      sub += u.Title;
            if (String.isNotBlank(u.Department)) sub += (sub != '' ? ' · ' : '') + u.Department;
            results.add(new LookupResult(u.Id, u.Name, sub));
        }
        return results;
    }

    /**
     * @description Returns all active Event__c records ordered by name.
     *              Called once when the wizard loads to pre-populate the
     *              Parent Event lookup options.
     *
     *              "Active" maps to Event_Status__c = 'Active'.
     *
     * @return  List<LookupResult> — id / name / subtitle (Event_Type__c)
     */
    @AuraEnabled(cacheable=true)
    public static List<LookupResult> getActiveEvents() {
        List<LookupResult> results = new List<LookupResult>();
        for (Event__c e : [
            SELECT Id, Name, Event_Type__c, Event_Start_Date__c
            FROM   Event__c
            WHERE  Event_Status__c = 'Active'
            ORDER BY Name
            LIMIT  500
        ]) {
            String sub = String.isNotBlank(e.Event_Type__c) ? e.Event_Type__c : '';
            if (e.Event_Start_Date__c != null)
                sub += (sub != '' ? ' · ' : '') + e.Event_Start_Date__c.format('MMM yyyy');
            results.add(new LookupResult(e.Id, e.Name, sub));
        }
        return results;
    }

    /**
     * @description Returns all Venue__c records ordered by name.
     *              Called once when the wizard loads to pre-populate the
     *              Venue lookup options.
     *
     * @return  List<LookupResult> — id / name / subtitle (Type · City, State)
     */
    @AuraEnabled(cacheable=true)
    public static List<LookupResult> getVenues() {
        List<LookupResult> results = new List<LookupResult>();
        for (Venue__c v : [
            SELECT Id, Name, Venue_Type__c, City__c, State__c
            FROM   Venue__c
            ORDER BY Name
            LIMIT  500
        ]) {
            String sub = String.isNotBlank(v.Venue_Type__c) ? v.Venue_Type__c : '';
            if (String.isNotBlank(v.City__c))  sub += (sub != '' ? ' · ' : '') + v.City__c;
            if (String.isNotBlank(v.State__c)) sub += ', ' + v.State__c;
            results.add(new LookupResult(v.Id, v.Name, sub));
        }
        return results;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Live search methods  (cacheable — called as the user types, ≥2 chars)
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Filters active internal users by name fragment.
     *              Backs the Event Manager type-ahead when the user types
     *              in the lookup input (complements getActiveUsers).
     */
    @AuraEnabled(cacheable=true)
    public static List<LookupResult> searchUsers(String searchTerm) {
        String q = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        List<LookupResult> results = new List<LookupResult>();
        for (User u : [
            SELECT Id, Name, Title, Department
            FROM   User
            WHERE  Name     LIKE :q
            AND    IsActive  = true
            AND    UserType  = 'Standard'
            ORDER BY Name
            LIMIT  10
        ]) {
            String sub = '';
            if (String.isNotBlank(u.Title))      sub += u.Title;
            if (String.isNotBlank(u.Department)) sub += (sub != '' ? ' · ' : '') + u.Department;
            results.add(new LookupResult(u.Id, u.Name, sub));
        }
        return results;
    }

    /**
     * @description Filters active Event__c records by name fragment.
     *              Backs the Parent Event type-ahead (complements getActiveEvents).
     */
    @AuraEnabled(cacheable=true)
    public static List<LookupResult> searchEvents(String searchTerm) {
        String q = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        List<LookupResult> results = new List<LookupResult>();
        for (Event__c e : [
            SELECT Id, Name, Event_Type__c, Event_Start_Date__c
            FROM   Event__c
            WHERE  Name            LIKE :q
            AND    Event_Status__c = 'Active'
            ORDER BY Name
            LIMIT  10
        ]) {
            String sub = String.isNotBlank(e.Event_Type__c) ? e.Event_Type__c : '';
            if (e.Event_Start_Date__c != null)
                sub += (sub != '' ? ' · ' : '') + e.Event_Start_Date__c.format('MMM yyyy');
            results.add(new LookupResult(e.Id, e.Name, sub));
        }
        return results;
    }

    /**
     * @description Filters Venue__c records by name fragment.
     *              Backs the Venue type-ahead (complements getVenues).
     */
    @AuraEnabled(cacheable=true)
    public static List<LookupResult> searchVenues(String searchTerm) {
        String q = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        List<LookupResult> results = new List<LookupResult>();
        for (Venue__c v : [
            SELECT Id, Name, Venue_Type__c, City__c, State__c
            FROM   Venue__c
            WHERE  Name LIKE :q
            ORDER BY Name
            LIMIT  10
        ]) {
            String sub = String.isNotBlank(v.Venue_Type__c) ? v.Venue_Type__c : '';
            if (String.isNotBlank(v.City__c))  sub += (sub != '' ? ' · ' : '') + v.City__c;
            if (String.isNotBlank(v.State__c)) sub += ', ' + v.State__c;
            results.add(new LookupResult(v.Id, v.Name, sub));
        }
        return results;
    }

    /**
     * @description Filters Contact records by name fragment.
     *              Backs the Primary Contact type-ahead in the New Venue modal.
     */
    @AuraEnabled(cacheable=true)
    public static List<LookupResult> searchContacts(String searchTerm) {
        String q = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        List<LookupResult> results = new List<LookupResult>();
        for (Contact c : [
            SELECT Id, Name, Title, Account.Name
            FROM   Contact
            WHERE  Name LIKE :q
            ORDER BY Name
            LIMIT  10
        ]) {
            String sub = c.Account != null ? c.Account.Name
                       : (String.isNotBlank(c.Title) ? c.Title : '');
            results.add(new LookupResult(c.Id, c.Name, sub));
        }
        return results;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Private helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * @description Converts an HTML datetime-local string ("2025-08-28T09:00"
     *              or "2025-08-28T09:00:00") to a Salesforce Datetime value.
     *              Uses JSON deserialization to avoid locale-dependent parsing.
     */
    private static Datetime parseDatetime(String isoString) {
        // Ensure seconds are present so JSON Datetime deserialization succeeds
        String s = isoString.contains(':')
            ? (isoString.length() == 16 ? isoString + ':00' : isoString)
            : isoString;
        return (Datetime) JSON.deserialize('"' + s + '"', Datetime.class);
    }

}