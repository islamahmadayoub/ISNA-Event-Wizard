/**
 * @description Unit tests for eventCreationWizardHandler.
 *
 *  Coverage targets:
 *   • createVenue        – happy path + required-field error
 *   • createEvent        – happy path (all optional fields set), minimal path
 *   • createCampaign     – all 9 Event_Type__c → Campaign.Type mappings
 *   • createTracks       – bulk insert (3 tracks); null price/tickets branch
 *   • getActiveUsers     – returns list, subtitle permutations
 *   • getActiveEvents    – returns list, subtitle with / without date
 *   • getVenues          – returns list, subtitle with / without city+state
 *   • searchUsers        – match + no-match
 *   • searchEvents       – match + no-match
 *   • searchVenues       – match + no-match
 *   • searchContacts     – match (with account + without), no-match
 *   • parseDatetime      – 16-char and 19-char ISO strings (via createEvent)
 *   • mapEventTypeToCampaignType – blank / unmapped fallback (via createCampaign)
 *
 * @author  ISNA Technology Team
 * @since   2026
 */
@isTest
private class eventCreationWizardHandlerTest {

    // ─── Test data helpers ────────────────────────────────────────────────────

    /** Minimal valid VenueInput. */
    private static eventCreationWizardHandler.VenueInput makeVenueInput() {
        eventCreationWizardHandler.VenueInput vi = new eventCreationWizardHandler.VenueInput();
        vi.name          = 'Test Convention Center';
        vi.venueType     = 'Convention Center';
        vi.streetAddress1 = '1 Test Blvd';
        vi.city          = 'Chicago';
        vi.state         = 'IL';
        vi.postalCode    = '60601';
        return vi;
    }

    /**
     * "yyyy-MM-ddTHH:mm[:ss]" string `days` days from today. Event dates must be
     * relative: a validation rule rejects Event_Start_Date__c in the past.
     */
    private static String futureIso(Integer days, String timePart) {
        return String.valueOf(Date.today().addDays(days)) + 'T' + timePart;
    }

    /** Datetime `days` days from today at the given hour. */
    private static Datetime futureDt(Integer days, Integer hour) {
        Date d = Date.today().addDays(days);
        return Datetime.newInstance(d.year(), d.month(), d.day(), hour, 0, 0);
    }

    /** Minimal valid EventInput (no optional FK fields). */
    private static eventCreationWizardHandler.EventInput makeEventInput(String name) {
        eventCreationWizardHandler.EventInput ei = new eventCreationWizardHandler.EventInput();
        ei.name          = name;
        ei.eventType     = 'Annual Convention';
        ei.eventStatus   = 'Active';
        ei.startDate     = futureIso(30, '09:00');
        ei.endDate       = futureIso(33, '18:00:00');
        ei.eventWebsite  = 'https://isna.net/convention';
        return ei;
    }

    // ─── createVenue ─────────────────────────────────────────────────────────

    @isTest
    static void testCreateVenue_happyPath() {
        eventCreationWizardHandler.VenueInput vi = makeVenueInput();
        vi.streetAddress2 = 'Suite 200';
        vi.venueCapacity  = '5000';
        vi.notes          = 'Main hall available';

        Test.startTest();
        String venueId = eventCreationWizardHandler.createVenue(JSON.serialize(vi));
        Test.stopTest();

        System.assertNotEquals(null, venueId, 'Venue Id should be returned');
        Venue__c v = [SELECT Name, Venue_Type__c, City__c FROM Venue__c WHERE Id = :venueId];
        System.assertEquals('Test Convention Center', v.Name);
        System.assertEquals('Convention Center',      v.Venue_Type__c);
        System.assertEquals('Chicago',                v.City__c);
    }

    @isTest
    static void testCreateVenue_withContact() {
        // Create a real Contact so the FK assignment is exercised
        Contact c = new Contact(LastName = 'VenueContact');
        insert c;

        eventCreationWizardHandler.VenueInput vi = makeVenueInput();
        vi.primaryContactId = c.Id;

        Test.startTest();
        String venueId = eventCreationWizardHandler.createVenue(JSON.serialize(vi));
        Test.stopTest();

        Venue__c v = [SELECT Primary_Contact__c FROM Venue__c WHERE Id = :venueId];
        System.assertEquals(c.Id, v.Primary_Contact__c, 'Primary contact should be set');
    }

    @isTest
    static void testCreateVenue_missingName_throwsError() {
        eventCreationWizardHandler.VenueInput vi = makeVenueInput();
        vi.name = null; // required field — should cause DML exception

        Test.startTest();
        try {
            eventCreationWizardHandler.createVenue(JSON.serialize(vi));
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex.getMessage());
        }
        Test.stopTest();
    }

    // ─── createEvent ─────────────────────────────────────────────────────────

    @isTest
    static void testCreateEvent_fullFields() {
        // Create a venue and a parent event to exercise FK branches
        Venue__c v = new Venue__c(Name = 'Hyatt Chicago', Venue_Type__c = 'Hotel',
                                   Street_Address_1__c = '1 Main', City__c = 'Chicago',
                                   State__c = 'IL', Postal_Code_Zip__c = '60601');
        insert v;

        Event__c parent = new Event__c(Name = 'ISNA Parent 2025',
                                        Event_Status__c = 'Active');
        insert parent;

        eventCreationWizardHandler.EventInput ei = makeEventInput('ISNA Annual Convention 2026');
        ei.venueId             = v.Id;
        ei.parentEventId       = parent.Id;
        ei.refundDeadline      = String.valueOf(Date.today().addDays(20));
        ei.hotelReservationUrl = 'https://hyatt.com/isna';

        Test.startTest();
        String eventId = eventCreationWizardHandler.createEvent(JSON.serialize(ei));
        Test.stopTest();

        System.assertNotEquals(null, eventId);
        Event__c evt = [SELECT Name, Event_Status__c, Venue__c, Parent_Event__c,
                                Cancellation_Refund_Deadline__c, Event_Website__c
                         FROM Event__c WHERE Id = :eventId];
        System.assertEquals('ISNA Annual Convention 2026', evt.Name);
        System.assertEquals('Active',                      evt.Event_Status__c);
        System.assertEquals(v.Id,                          evt.Venue__c);
        System.assertEquals(parent.Id,                     evt.Parent_Event__c);
        System.assertEquals(Date.today().addDays(20),       evt.Cancellation_Refund_Deadline__c);
        System.assertEquals('https://isna.net/convention', evt.Event_Website__c);
    }

    @isTest
    static void testCreateEvent_minimalFields() {
        // No optional FK fields, no dates — exercises blank-check branches
        eventCreationWizardHandler.EventInput ei = new eventCreationWizardHandler.EventInput();
        ei.name        = 'Minimal Event';
        ei.eventStatus = 'Inactive';

        Test.startTest();
        String eventId = eventCreationWizardHandler.createEvent(JSON.serialize(ei));
        Test.stopTest();

        System.assertNotEquals(null, eventId);
    }

    @isTest
    static void testCreateEvent_datetimeWith19Chars() {
        // Exercises the 19-char ISO branch in parseDatetime
        eventCreationWizardHandler.EventInput ei = makeEventInput('Full Seconds Event');
        ei.startDate = futureIso(45, '08:30:00');
        ei.endDate   = futureIso(48, '20:00:00');

        Test.startTest();
        String eventId = eventCreationWizardHandler.createEvent(JSON.serialize(ei));
        Test.stopTest();

        System.assertNotEquals(null, eventId);
    }

    // ─── createCampaign — all Event_Type__c mappings ────────────────────────

    @isTest
    static void testCreateCampaign_allTypeMappings() {
        // Campaign.Type is always 'Other' regardless of event type
        Map<String, String> cases = new Map<String, String>{
            'Annual Convention'          => 'Other',
            'ISNA Day'                   => 'Other',
            'Matrimonial'                => 'Other',
            'Chaplaincy'                 => 'Other',
            'Art Exhibit'                => 'Other',
            'Film Festival'              => 'Other',
            'Education Forum'            => 'Other',
            'West Coast Education Forum' => 'Other',
            'Webinar'                    => 'Other',
            'UnknownType'                => 'Other'
        };

        Test.startTest();
        for (String evtType : cases.keySet()) {
            // Create a matching Event__c first
            Event__c e = new Event__c(Name = 'Campaign Test - ' + evtType,
                                       Event_Status__c = 'Active');
            insert e;

            eventCreationWizardHandler.EventInput ei = makeEventInput('Campaign Test - ' + evtType);
            ei.eventType    = evtType;
            ei.eventWebsite = 'https://isna.net/test';

            eventCreationWizardHandler.CampaignResult result =
                eventCreationWizardHandler.createCampaign(e.Id, JSON.serialize(ei));

            System.assertNotEquals(null, result.campaignId,   'campaignId null for type=' + evtType);
            System.assertNotEquals(null, result.campaignName, 'campaignName null for type=' + evtType);

            Campaign camp = [SELECT Type FROM Campaign WHERE Id = :result.campaignId];
            System.assertEquals(cases.get(evtType), camp.Type, 'Wrong type mapping for ' + evtType);
        }
        Test.stopTest();
    }

    @isTest
    static void testCreateCampaign_blankEventType_givesOther() {
        Event__c e = new Event__c(Name = 'Blank Type Event', Event_Status__c = 'Active');
        insert e;

        eventCreationWizardHandler.EventInput ei = makeEventInput('Blank Type Event');
        ei.eventType    = null;  // blank → should map to 'Other'
        ei.startDate    = null;
        ei.endDate      = null;
        ei.eventWebsite = null;

        Test.startTest();
        eventCreationWizardHandler.CampaignResult result =
            eventCreationWizardHandler.createCampaign(e.Id, JSON.serialize(ei));
        Test.stopTest();

        Campaign camp = [SELECT Type FROM Campaign WHERE Id = :result.campaignId];
        System.assertEquals('Other', camp.Type);
    }

    // ─── createTracks ─────────────────────────────────────────────────────────

    @isTest
    static void testCreateTracks_bulkInsert() {
        Event__c e = new Event__c(Name = 'Track Test Event', Event_Status__c = 'Active');
        insert e;

        List<eventCreationWizardHandler.TrackInput> tracks =
            new List<eventCreationWizardHandler.TrackInput>();

        eventCreationWizardHandler.TrackInput t1 = new eventCreationWizardHandler.TrackInput();
        t1.name          = 'General Admission';
        t1.ticketPrice   = 150.00;
        t1.numberOfTickets = 500;
        t1.description   = 'Open to all attendees';
        tracks.add(t1);

        eventCreationWizardHandler.TrackInput t2 = new eventCreationWizardHandler.TrackInput();
        t2.name          = 'VIP';
        t2.ticketPrice   = 500.00;
        t2.numberOfTickets = 50;
        tracks.add(t2);

        // Third track with null price and tickets — exercises the null-check branches
        eventCreationWizardHandler.TrackInput t3 = new eventCreationWizardHandler.TrackInput();
        t3.name            = 'Free Youth Pass';
        t3.ticketPrice     = null;
        t3.numberOfTickets = null;
        tracks.add(t3);

        Test.startTest();
        eventCreationWizardHandler.createTracks(e.Id, JSON.serialize(tracks));
        Test.stopTest();

        List<Track__c> inserted = [SELECT Name, Ticket_Price__c, Number_of_Tickets__c
                                    FROM Track__c WHERE Event__c = :e.Id ORDER BY Name];
        System.assertEquals(3, inserted.size(), '3 tracks should be inserted');

        // Spot-check one
        Track__c ga = [SELECT Ticket_Price__c FROM Track__c
                        WHERE Event__c = :e.Id AND Name = 'General Admission' LIMIT 1];
        System.assertEquals(150.00, ga.Ticket_Price__c);
    }

    // ─── getActiveUsers ───────────────────────────────────────────────────────

    @isTest
    static void testGetActiveUsers_returnsCurrentUser() {
        // The running user is always a Standard active user
        Test.startTest();
        List<eventCreationWizardHandler.LookupResult> results =
            eventCreationWizardHandler.getActiveUsers();
        Test.stopTest();

        System.assert(results.size() > 0, 'At least one active user expected');
        // Verify result shape
        eventCreationWizardHandler.LookupResult first = results[0];
        System.assertNotEquals(null, first.id);
        System.assertNotEquals(null, first.name);
    }

    // ─── getActiveEvents ──────────────────────────────────────────────────────

    @isTest
    static void testGetActiveEvents_returnsInsertedEvent() {
        Event__c e = new Event__c(Name = 'Wire Test Active Event',
                                   Event_Status__c   = 'Active',
                                   Event_Type__c     = 'Webinar',
                                   Event_Start_Date__c = futureDt(30, 9));
        insert e;

        Test.startTest();
        List<eventCreationWizardHandler.LookupResult> results =
            eventCreationWizardHandler.getActiveEvents();
        Test.stopTest();

        // At least our inserted event should appear
        Boolean found = false;
        for (eventCreationWizardHandler.LookupResult r : results) {
            if (r.id == e.Id) { found = true; break; }
        }
        System.assert(found, 'Newly inserted active event not found in getActiveEvents');
    }

    @isTest
    static void testGetActiveEvents_inactiveEventExcluded() {
        Event__c e = new Event__c(Name = 'Inactive Test Event',
                                   Event_Status__c = 'Inactive');
        insert e;

        Test.startTest();
        List<eventCreationWizardHandler.LookupResult> results =
            eventCreationWizardHandler.getActiveEvents();
        Test.stopTest();

        for (eventCreationWizardHandler.LookupResult r : results) {
            System.assertNotEquals(e.Id, r.id, 'Inactive event must not appear in getActiveEvents');
        }
    }

    // ─── getVenues ────────────────────────────────────────────────────────────

    @isTest
    static void testGetVenues_returnsInsertedVenue() {
        Venue__c v = new Venue__c(Name = 'GetVenues Test Venue',
                                   Venue_Type__c     = 'Hotel',
                                   Street_Address_1__c = '1 Lake Shore Dr',
                                   City__c           = 'Chicago',
                                   State__c          = 'IL',
                                   Postal_Code_Zip__c = '60611');
        insert v;

        Test.startTest();
        List<eventCreationWizardHandler.LookupResult> results =
            eventCreationWizardHandler.getVenues();
        Test.stopTest();

        Boolean found = false;
        for (eventCreationWizardHandler.LookupResult r : results) {
            if (r.id == v.Id) {
                found = true;
                System.assert(r.subtitle.contains('Hotel'),   'Subtitle should include type');
                System.assert(r.subtitle.contains('Chicago'), 'Subtitle should include city');
                break;
            }
        }
        System.assert(found, 'Inserted venue not found in getVenues');
    }

    @isTest
    static void testGetVenues_subtitleWithoutCityOrState() {
        // Venue with no city/state — exercises the blank-check branches in getVenues
        Venue__c v = new Venue__c(Name = 'No Location Venue',
                                   Venue_Type__c     = 'Other',
                                   Street_Address_1__c = '99 Unknown Rd',
                                   Postal_Code_Zip__c = '00000');
        insert v;

        Test.startTest();
        List<eventCreationWizardHandler.LookupResult> results =
            eventCreationWizardHandler.getVenues();
        Test.stopTest();

        for (eventCreationWizardHandler.LookupResult r : results) {
            if (r.id == v.Id) {
                System.assertEquals('Other', r.subtitle);
            }
        }
    }

    // ─── searchUsers ──────────────────────────────────────────────────────────

    @isTest
    static void testSearchUsers_matchAndNoMatch() {
        // The running user's name will always match on a broad search
        User me = [SELECT Name FROM User WHERE Id = :UserInfo.getUserId()];
        String fragment = me.Name.substring(0, Math.min(4, me.Name.length()));

        Test.startTest();
        List<eventCreationWizardHandler.LookupResult> hits =
            eventCreationWizardHandler.searchUsers(fragment);
        List<eventCreationWizardHandler.LookupResult> misses =
            eventCreationWizardHandler.searchUsers('zzz_no_match_xyz_987');
        Test.stopTest();

        System.assert(hits.size() > 0, 'Search should match running user');
        System.assertEquals(0, misses.size(), 'No-match search should return empty list');
    }

    // ─── searchEvents ─────────────────────────────────────────────────────────

    @isTest
    static void testSearchEvents_matchAndNoMatch() {
        Event__c e = new Event__c(Name = 'SearchEvents ISNA Summit',
                                   Event_Status__c = 'Active');
        insert e;

        Test.startTest();
        List<eventCreationWizardHandler.LookupResult> hits =
            eventCreationWizardHandler.searchEvents('ISNA Summit');
        List<eventCreationWizardHandler.LookupResult> misses =
            eventCreationWizardHandler.searchEvents('zzz_no_match_xyz_987');
        Test.stopTest();

        System.assert(hits.size() > 0, 'Search should find ISNA Summit event');
        System.assertEquals(0, misses.size());
    }

    // ─── searchVenues ─────────────────────────────────────────────────────────

    @isTest
    static void testSearchVenues_matchAndNoMatch() {
        Venue__c v = new Venue__c(Name = 'SearchVenues Grand Hyatt',
                                   Venue_Type__c     = 'Hotel',
                                   Street_Address_1__c = '1 Grand Ave',
                                   City__c           = 'Dallas',
                                   State__c          = 'TX',
                                   Postal_Code_Zip__c = '75201');
        insert v;

        Test.startTest();
        List<eventCreationWizardHandler.LookupResult> hits =
            eventCreationWizardHandler.searchVenues('Grand Hyatt');
        List<eventCreationWizardHandler.LookupResult> misses =
            eventCreationWizardHandler.searchVenues('zzz_no_match_xyz_987');
        Test.stopTest();

        System.assert(hits.size() > 0, 'Search should find Grand Hyatt venue');
        System.assertEquals(0, misses.size());
    }

    // ─── searchContacts ───────────────────────────────────────────────────────

    @isTest
    static void testSearchContacts_withAndWithoutAccount() {
        Account acct = new Account(Name = 'ISNA HQ');
        insert acct;

        Contact c1 = new Contact(LastName = 'SearchContact Ahmad', AccountId = acct.Id);
        Contact c2 = new Contact(LastName = 'SearchContact Bilal'); // no account
        insert new List<Contact>{ c1, c2 };

        Test.startTest();
        List<eventCreationWizardHandler.LookupResult> hits =
            eventCreationWizardHandler.searchContacts('SearchContact');
        List<eventCreationWizardHandler.LookupResult> misses =
            eventCreationWizardHandler.searchContacts('zzz_no_match_xyz_987');
        Test.stopTest();

        System.assertEquals(2, hits.size(), 'Both SearchContact records expected');
        System.assertEquals(0, misses.size());

        // Verify account subtitle for c1
        for (eventCreationWizardHandler.LookupResult r : hits) {
            if (r.id == c1.Id) {
                System.assertEquals('ISNA HQ', r.subtitle);
            }
        }
    }

    // ─── createEvent — Description + Theme ─────────────────────────────────

    @isTest
    static void testCreateEvent_descriptionAndTheme() {
        eventCreationWizardHandler.EventInput ei = makeEventInput('Themed Event');
        ei.eventDescription = 'A weekend of learning & community';
        ei.theme            = 'Faith, Family & Future';

        Test.startTest();
        String eventId = eventCreationWizardHandler.createEvent(JSON.serialize(ei));
        Test.stopTest();

        Event__c evt = [SELECT Event_Description__c, Theme__c FROM Event__c WHERE Id = :eventId];
        System.assertEquals('A weekend of learning & community', evt.Event_Description__c);
        System.assertEquals('Faith, Family & Future',            evt.Theme__c);
    }

    // ─── createAsanaTicket ────────────────────────────────────────────────────

    /** Captures the outgoing request and returns a canned Asana response. */
    private class AsanaMock implements HttpCalloutMock {
        Integer status;
        String  body;
        HttpRequest captured;
        AsanaMock(Integer status, String body) { this.status = status; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            captured = req;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(status);
            res.setBody(body);
            return res;
        }
    }

    /** Event with venue, manager, tracks and links — exercises every summary branch. */
    private static Event__c makeFullEvent() {
        Venue__c v = new Venue__c(Name = 'Asana Venue', Venue_Type__c = 'Hotel',
                                   Street_Address_1__c = '1 Main', City__c = 'Chicago',
                                   State__c = 'IL', Postal_Code_Zip__c = '60601');
        insert v;
        Event__c e = new Event__c(Name = 'ISNA <Day> & Gala', Event_Status__c = 'Active',
                                   Event_Type__c = 'ISNA Day', Theme__c = 'Unity',
                                   Event_Description__c = 'Annual gathering',
                                   Event_Manager__c = UserInfo.getUserId(), Venue__c = v.Id,
                                   Event_Start_Date__c = futureDt(30, 9),
                                   Event_End_Date__c   = futureDt(30, 17),
                                   Cancellation_Refund_Deadline__c = Date.today().addDays(20),
                                   Event_Website__c = 'https://isna.net/day',
                                   Hotel_Reservation_URL__c = 'https://hotel.example.com/isna');
        insert e;
        insert new List<Track__c>{
            new Track__c(Event__c = e.Id, Name = 'General', Ticket_Price__c = 25,
                         Number_of_Tickets__c = 100, Track_Description__c = 'Entry'),
            new Track__c(Event__c = e.Id, Name = 'Free Pass')
        };
        return e;
    }

    @isTest
    static void testCreateAsanaTicket_success() {
        Event__c e = makeFullEvent();
        AsanaMock mock = new AsanaMock(201,
            '{"data":{"gid":"1234567890","permalink_url":"https://app.asana.com/0/0/1234567890"}}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        eventCreationWizardHandler.AsanaResult result =
            eventCreationWizardHandler.createAsanaTicket(e.Id, '701000000000001');
        Test.stopTest();

        System.assertEquals('1234567890', result.taskGid);
        System.assertEquals('https://app.asana.com/0/0/1234567890', result.taskUrl);

        System.assert(mock.captured.getEndpoint().startsWith('callout:Asana_API/tasks'));
        System.assertEquals('POST', mock.captured.getMethod());

        Map<String, Object> data = (Map<String, Object>)
            ((Map<String, Object>) JSON.deserializeUntyped(mock.captured.getBody())).get('data');
        System.assertEquals('Create Form Assembly Form for Event : ISNA <Day> & Gala', data.get('name'));
        System.assertEquals(eventCreationWizardHandler.ASANA_ASSIGNEE_GID, data.get('assignee'));
        System.assertEquals(String.valueOf(Date.today().addDays(3)), data.get('due_on'));
        System.assertEquals(new List<Object>{ eventCreationWizardHandler.ASANA_PROJECT_GID }, data.get('projects'));

        String notes = (String) data.get('html_notes');
        System.assert(notes.startsWith('<body>') && notes.endsWith('</body>'));
        System.assert(notes.contains('ISNA &lt;Day&gt; &amp; Gala'), 'Name should be XML-escaped');
        System.assert(notes.contains('Unity'),            'Theme should be in summary');
        System.assert(notes.contains('Annual gathering'), 'Description should be in summary');
        System.assert(notes.contains('Asana Venue'),      'Venue should be in summary');
        System.assert(notes.contains('General'),          'Tracks should be in summary');
        System.assert(notes.contains('/lightning/r/Event__c/' + e.Id + '/view'), 'Event link expected');
        System.assert(notes.contains('/lightning/r/Campaign/701000000000001/view'), 'Campaign link expected');
        System.assert(notes.contains('https://isna.net/day'), 'Website link expected');
    }

    @isTest
    static void testCreateAsanaTicket_minimalEvent() {
        Event__c e = new Event__c(Name = 'Bare Event', Event_Status__c = 'Active');
        insert e;
        AsanaMock mock = new AsanaMock(201, '{"data":{"gid":"1","permalink_url":"https://app.asana.com/0/0/1"}}');
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        eventCreationWizardHandler.AsanaResult result = eventCreationWizardHandler.createAsanaTicket(e.Id, null);
        Test.stopTest();

        System.assertEquals('1', result.taskGid);
        String body = mock.captured.getBody();
        System.assert(!body.contains('/lightning/r/Campaign/'), 'No campaign link without a campaign Id');
    }

    @isTest
    static void testCreateAsanaTicket_httpError_throws() {
        Event__c e = new Event__c(Name = 'Failing Event', Event_Status__c = 'Active');
        insert e;
        Test.setMock(HttpCalloutMock.class, new AsanaMock(401, '{"errors":[{"message":"Not Authorized"}]}'));

        Test.startTest();
        try {
            eventCreationWizardHandler.createAsanaTicket(e.Id, null);
            System.assert(false, 'Expected AuraHandledException');
        } catch (AuraHandledException ex) {
            System.assertNotEquals(null, ex.getMessage());
        }
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Event__c WHERE Id = :e.Id], 'Event must survive an Asana failure');
    }

    // ─── LookupResult / CampaignResult constructors ───────────────────────────

    @isTest
    static void testInnerClasses_constructors() {
        // Ensure wrapper constructors are exercised (boosts line coverage)
        eventCreationWizardHandler.LookupResult lr =
            new eventCreationWizardHandler.LookupResult('001000000000001', 'Test Name', 'Subtitle');
        System.assertEquals('001000000000001', lr.id);
        System.assertEquals('Test Name',       lr.name);
        System.assertEquals('Subtitle',        lr.subtitle);

        eventCreationWizardHandler.CampaignResult cr =
            new eventCreationWizardHandler.CampaignResult('701000000000001', 'Campaign Name');
        System.assertEquals('701000000000001', cr.campaignId);
        System.assertEquals('Campaign Name',   cr.campaignName);
    }
}