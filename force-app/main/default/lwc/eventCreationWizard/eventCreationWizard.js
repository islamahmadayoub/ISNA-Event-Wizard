import { LightningElement, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

// ── DML methods ───────────────────────────────────────────────────────────────
import createVenue   from '@salesforce/apex/eventCreationWizardHandler.createVenue';
import createEvent   from '@salesforce/apex/eventCreationWizardHandler.createEvent';
import createCampaign from '@salesforce/apex/eventCreationWizardHandler.createCampaign';
import createTracks  from '@salesforce/apex/eventCreationWizardHandler.createTracks';

// ── Integration ───────────────────────────────────────────────────────────────
import createAsanaTicket from '@salesforce/apex/eventCreationWizardHandler.createAsanaTicket';

// ── Initial-load query methods (wired on connectedCallback) ───────────────────
import getActiveUsers  from '@salesforce/apex/eventCreationWizardHandler.getActiveUsers';
import getActiveEvents from '@salesforce/apex/eventCreationWizardHandler.getActiveEvents';
import getVenues       from '@salesforce/apex/eventCreationWizardHandler.getVenues';

// ── Live search (contact only – contacts are not pre-loaded) ──────────────────
import searchContacts from '@salesforce/apex/eventCreationWizardHandler.searchContacts';

const TEAL  = '#229492';
const GREEN = '#6fbd4b';
const NAVY  = '#003777';
const TRACK_COLORS = [TEAL, NAVY, GREEN, '#7c3aed', '#db6b1a'];

let _nextId = 3;

export default class EventCreationWizard extends NavigationMixin(LightningElement) {

    // ── Wizard state ──────────────────────────────────────────────────────────
    @track currentStep     = 1;
    @track showVenueModal  = false;
    @track isLoading       = false;
    @track saveError       = '';

    // Published record Ids (shown on the success screen)
    @track publishedEventId    = '';
    @track publishedCampaignId = '';
    @track publishedCampaignName = '';
    @track asanaTaskUrl          = '';
    @track asanaError            = '';
    @track idCopied              = false;

    // ── Step 1 – Event fields ─────────────────────────────────────────────────
    @track eventName          = '';
    @track eventType          = '';
           eventStatus        = 'Active';   // always 'Active'; not exposed in UI
    @track eventDescription   = '';
    @track theme              = '';
    @track eventManagerName   = '';
    @track eventManagerId     = '';
    @track parentEventName    = '';
    @track parentEventId      = '';
    @track startDate          = '';
    @track endDate            = '';
    @track refundDeadline     = '';
    @track venueName_display  = '';
    @track venueId            = '';
    @track hotelLink          = '';
    @track eventWebsite       = '';
    @track errors             = {};

    // ── Step 2 – Ticket tracks ────────────────────────────────────────────────
    @track tracks = [
        { id: 1, name: '', price: '', tickets: '', description: '' }
    ];

    // ── Venue modal fields ────────────────────────────────────────────────────
    @track venueModalName        = '';
    @track venueModalType        = '';
    @track venueModalAddress1    = '';
    @track venueModalAddress2    = '';
    @track venueModalCity        = '';
    @track venueModalState       = '';
    @track venueModalZip         = '';
    @track venueModalCapacity    = '';
    @track venueModalContactName = '';
    @track venueModalContactId   = '';
    @track venueModalNotes       = '';
    @track venueErrors           = {};

    // ── Pre-loaded lookup data (from @wire calls) ─────────────────────────────
    _allUsers  = [];   // full list from getActiveUsers
    _allEvents = [];   // full list from getActiveEvents
    _allVenues = [];   // full list from getVenues

    // ── Filtered dropdown options shown to the user ───────────────────────────
    @track managerResults  = [];
    @track parentResults   = [];
    @track venueResults    = [];
    @track contactResults  = [];

    // ── Wire: load active users on component init ─────────────────────────────
    /**
     * Populates the Event Manager lookup with active internal (Standard) users.
     * Up to 500 records; further filtering is done client-side as the user types.
     */
    @wire(getActiveUsers)
    wiredUsers({ data, error }) {
        if (data)  { this._allUsers = data;  }
        if (error) { console.error('getActiveUsers error', error); }
    }

    // ── Wire: load active events on component init ────────────────────────────
    /**
     * Populates the Parent Event lookup with Event__c records where
     * Event_Status__c = 'Active'. Up to 500 records; filtered client-side.
     */
    @wire(getActiveEvents)
    wiredEvents({ data, error }) {
        if (data)  { this._allEvents = data; }
        if (error) { console.error('getActiveEvents error', error); }
    }

    // ── Wire: load all venues on component init ───────────────────────────────
    /**
     * Populates the Venue lookup with all Venue__c records (up to 500).
     * Filtered client-side as the user types; newly created venues are
     * prepended to the list after a successful createVenue call.
     */
    @wire(getVenues)
    wiredVenues({ data, error }) {
        if (data)  { this._allVenues = data; }
        if (error) { console.error('getVenues error', error); }
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────
    connectedCallback() {
        const d = this._defaultDates();
        this.startDate     = d.startDate;
        this.endDate       = d.endDate;
        this.refundDeadline = d.refundDeadline;
    }

    // Force the <select> to reflect the tracked value after every render.
    // LWC does not reliably apply the `selected` attribute on <option> elements,
    // so we set the select's value imperatively here instead.
    renderedCallback() {
        const sel = this.template.querySelector('select[data-field="eventType"]');
        if (sel && sel.value !== this.eventType) {
            sel.value = this.eventType;
        }
    }

    /** Returns { startDate, endDate, refundDeadline } with sensible defaults. */
    _defaultDates() {
        const now   = new Date();
        // First day of next month
        const start = new Date(now.getFullYear(), now.getMonth() + 1, 1);
        const pad   = n => String(n).padStart(2, '0');
        const ymd   = d => `${d.getFullYear()}-${pad(d.getMonth()+1)}-${pad(d.getDate())}`;
        const refund = new Date(start);
        refund.setDate(refund.getDate() + 20);
        return {
            startDate:      `${ymd(start)}T09:00`,
            endDate:        `${ymd(start)}T17:00`,
            refundDeadline: ymd(refund),
        };
    }

    /** Recomputes refundDeadline to 20 days after the given start datetime string. */
    _updateRefundDeadline(startDateStr) {
        if (!startDateStr) return;
        // datetime-local value is "YYYY-MM-DDTHH:MM"; parse as local date
        const [datePart] = startDateStr.split('T');
        const [y, m, d]  = datePart.split('-').map(Number);
        const refund = new Date(y, m - 1, d + 20);
        const pad    = n => String(n).padStart(2, '0');
        this.refundDeadline = `${refund.getFullYear()}-${pad(refund.getMonth()+1)}-${pad(refund.getDate())}`;
    }

    // ── Logo ──────────────────────────────────────────────────────────────────
    get logoUrl() { return '/resource/isna_logo'; }
    hideLogoImg(e) { e.target.style.display = 'none'; }

    // ── Step visibility ───────────────────────────────────────────────────────
    get isStep1()        { return this.currentStep === 1; }
    get isStep2()        { return this.currentStep === 2; }
    get isStep3()        { return this.currentStep === 3; }
    get isStep4()        { return this.currentStep === 4; }
    get showStepHeader() { return this.currentStep < 4;  }
    get breadcrumbLabel(){ return this.currentStep === 4 ? 'Published' : 'New Event'; }

    get stepHeading() {
        return { 1: 'Create New Event', 2: 'Ticket Types', 3: 'Review & Publish' }[this.currentStep] || '';
    }
    get stepSubtitle() {
        return {
            1: 'Fill in the event details below. Required fields are marked with',
            2: `Define ticket types for ${this.eventName || 'your event'}.`,
            3: 'Review all details before publishing.'
        }[this.currentStep] || '';
    }

    // ── Progress bar helpers ──────────────────────────────────────────────────
    _circleStyle(n) {
        const done = n < this.currentStep, active = n === this.currentStep;
        if (done)   return `background:${TEAL};color:#fff;border-color:${TEAL}`;
        if (active) return `background:${NAVY};color:#fff;border-color:${TEAL}`;
        return 'background:#e5e7eb;color:#9ca3af;border-color:transparent';
    }
    _labelStyle(n) {
        const done = n < this.currentStep, active = n === this.currentStep;
        if (active) return `color:${NAVY};font-weight:600`;
        if (done)   return `color:${TEAL}`;
        return 'color:#6b7280';
    }
    _lineStyle(n)   { return `background:${n < this.currentStep ? TEAL : '#e5e7eb'}`; }
    _display(n)     { return n < this.currentStep ? '✓' : String(n); }

    get step1CircleStyle() { return this._circleStyle(1); }
    get step2CircleStyle() { return this._circleStyle(2); }
    get step3CircleStyle() { return this._circleStyle(3); }
    get step1LabelStyle()  { return this._labelStyle(1); }
    get step2LabelStyle()  { return this._labelStyle(2); }
    get step3LabelStyle()  { return this._labelStyle(3); }
    get line1Style()       { return this._lineStyle(1); }
    get line2Style()       { return this._lineStyle(2); }
    get step1Display()     { return this._display(1); }
    get step2Display()     { return this._display(2); }
    get step3Display()     { return this._display(3); }

    // ── Select options (from real Salesforce picklist values) ─────────────────
    get eventTypeOptions() {
        return ['Annual Convention','Education Forum','Matrimonial',
                'West Coast Education Forum','ISNA Day','Webinar',
                'Chaplaincy','Art Exhibit','Film Festival']
            .map(o => ({ label: o, value: o }));
    }
    // Venue_Type__c picklist
    get venueTypeOptions() {
        return ['Convention Center','Hotel','Museum','Other','Restaurant']
            .map(o => ({ label: o, value: o, selected: o === this.venueModalType }));
    }

    // ── Client-side lookup filter helper ──────────────────────────────────────
    /**
     * Filters a pre-loaded LookupResult[] by name (case-insensitive).
     * Returns the first 10 matches, or the first 10 records when term is blank.
     */
    _filterList(list, term) {
        if (!list || !list.length) return [];
        const t = (term || '').trim().toLowerCase();
        const filtered = t.length
            ? list.filter(r => r.name.toLowerCase().includes(t))
            : list;
        return filtered.slice(0, 10);
    }

    // ── Event Manager lookup ──────────────────────────────────────────────────
    /** Show pre-loaded users when the field receives focus. */
    handleManagerFocus() {
        this.managerResults = this._filterList(this._allUsers, this.eventManagerName);
        this.onFocus(...arguments);
    }
    /** Filter the pre-loaded user list client-side as the user types. */
    handleManagerInput(e) {
        this.eventManagerName = e.target.value;
        this.eventManagerId   = '';   // clear stale Id when the user retypes
        this.managerResults   = this._filterList(this._allUsers, this.eventManagerName);
    }
    selectManager(e) {
        const { id, name } = e.currentTarget.dataset;
        this.eventManagerId   = id;
        this.eventManagerName = name;
        this.managerResults   = [];
    }
    clearManager() {
        this.eventManagerId   = '';
        this.eventManagerName = '';
        this.managerResults   = [];
    }

    // ── Parent Event lookup ───────────────────────────────────────────────────
    /** Show active events when the field receives focus. */
    handleParentFocus() {
        this.parentResults = this._filterList(this._allEvents, this.parentEventName);
        this.onFocus(...arguments);
    }
    /** Filter the pre-loaded events list client-side as the user types. */
    handleParentInput(e) {
        this.parentEventName = e.target.value;
        this.parentEventId   = '';
        this.parentResults   = this._filterList(this._allEvents, this.parentEventName);
    }
    selectParent(e) {
        const { id, name } = e.currentTarget.dataset;
        this.parentEventId   = id;
        this.parentEventName = name;
        this.parentResults   = [];
    }
    clearParent() {
        this.parentEventId   = '';
        this.parentEventName = '';
        this.parentResults   = [];
    }

    // ── Venue lookup ──────────────────────────────────────────────────────────
    /** Show all venues when the field receives focus. */
    handleVenueFocus() {
        this.venueResults = this._filterList(this._allVenues, this.venueName_display);
        this.onFocus(...arguments);
    }
    /** Filter the pre-loaded venues list client-side as the user types. */
    handleVenueInput(e) {
        this.venueName_display = e.target.value;
        this.venueId           = '';
        this.venueResults      = this._filterList(this._allVenues, this.venueName_display);
    }
    selectVenue(e) {
        const { id, name } = e.currentTarget.dataset;
        this.venueId          = id;
        this.venueName_display = name;
        this.venueResults     = [];
    }
    clearVenue() {
        this.venueId          = '';
        this.venueName_display = '';
        this.venueResults     = [];
    }

    // ── Contact lookup (Apex search – contacts are not pre-loaded) ────────────
    async handleContactSearch(e) {
        this.venueModalContactName = e.target.value;
        if (this.venueModalContactName.length < 2) { this.contactResults = []; return; }
        this.contactResults = await searchContacts({ searchTerm: this.venueModalContactName });
    }
    selectContact(e) {
        const { id, name } = e.currentTarget.dataset;
        this.venueModalContactId   = id;
        this.venueModalContactName = name;
        this.contactResults        = [];
    }
    clearContact() {
        this.venueModalContactId   = '';
        this.venueModalContactName = '';
        this.contactResults        = [];
    }

    // ── Generic input + focus / blur handlers ─────────────────────────────────
    handleInput(e) {
        const field = e.target.dataset.field;
        this[field] = e.target.value;
        if (field === 'startDate') this._updateRefundDeadline(e.target.value);
    }
    handleVenueInputField(e) { this[e.target.dataset.field] = e.target.value; }

    onFocus(e) { if (e?.target) e.target.style.borderColor = TEAL; }
    onBlur(e)  { if (e?.target) e.target.style.borderColor = '#d1d5db'; }

    // Prevent the input from losing focus when the user clicks a dropdown option.
    // mousedown fires before blur, so calling preventDefault() here keeps focus
    // on the input, allowing the subsequent click event to select the option.
    // This lets the blur handlers close the dropdown instantly with no delay.
    handleDropdownMousedown(e) { e.preventDefault(); }

    handleManagerBlur(e) { this.onBlur(e); this.managerResults = []; }
    handleParentBlur(e)  { this.onBlur(e); this.parentResults  = []; }
    handleVenueBlur(e)   { this.onBlur(e); this.venueResults   = []; }

    // ── Step 1 – validation & advance ─────────────────────────────────────────
    handleNext1() {
        const errs = {};
        if (!this.eventName.trim()) errs.name      = 'Event Name is required.';
        if (!this.eventType)        errs.type      = 'Event Type is required.';
        if (!this.startDate)        errs.startDate = 'Start Date is required.';
        if (!this.endDate)          errs.endDate   = 'End Date is required.';

        // Lookup fields (Event Manager / Parent Event / Venue) only persist to
        // the record when an Id has been captured via selectManager/selectParent/
        // selectVenue (i.e. the user clicked a dropdown match). Typing a name and
        // tabbing away leaves the Id blank while the text stays on screen, which
        // silently saves the record with that relationship field empty even
        // though the wizard appears to show a value. Block advancing in that case.
        if (this.eventManagerName.trim() && !this.eventManagerId)
            errs.manager = 'Select a match from the dropdown, or clear this field.';
        if (this.parentEventName.trim() && !this.parentEventId)
            errs.parent = 'Select a match from the dropdown, or clear this field.';
        if (this.venueName_display.trim() && !this.venueId)
            errs.venue = 'Select a match from the dropdown, or clear this field.';

        this.errors = errs;
        if (!Object.keys(errs).length) {
            this.managerResults = [];
            this.parentResults  = [];
            this.venueResults   = [];
            this.currentStep    = 2;
        }
    }
    goToStep1() { if (this.currentStep > 1) this.currentStep = 1; }
    goBack()    { this.currentStep -= 1; }
    goToStep3() { this.currentStep = 3; }

    // ── Step 2 – Track handlers ───────────────────────────────────────────────
    handleTrackInput(e) {
        const id    = parseInt(e.target.dataset.id, 10);
        const field = e.target.dataset.field;
        this.tracks = this.tracks.map(t => t.id === id ? { ...t, [field]: e.target.value } : t);
    }
    addTrack() {
        this.tracks = [...this.tracks, {
            id: _nextId++, name: '', price: '', tickets: '1', description: ''
        }];
    }
    deleteTrack(e) {
        const id = parseInt(e.currentTarget.dataset.id, 10);
        this.tracks = this.tracks.filter(t => t.id !== id);
    }

    // ── Tracks computed for rendering ─────────────────────────────────────────
    get tracksWithMeta() {
        return this.tracks.map((t, i) => ({
            ...t,
            displayNum:     i + 1,
            headerStyle:    `background:${TRACK_COLORS[i % TRACK_COLORS.length]}`,
            nameDisplay:    t.name || `Track ${i + 1}`,
            formattedPrice: t.price ? `$${parseFloat(t.price).toFixed(2)}` : '',
            isNotOnly:      this.tracks.length > 1
        }));
    }

    // ── Review rows (Step 3) ──────────────────────────────────────────────────
    get reviewEventRows() {
        const fmt = v => v ? v.replace('T', '  ') : '—';
        return [
            { key: 'name',    label: 'Event Name',                    value: this.eventName         || '—' },
            { key: 'type',    label: 'Event Type',                    value: this.eventType         || '—' },
            { key: 'theme',   label: 'Theme',                         value: this.theme             || '—' },
            { key: 'desc',    label: 'Event Description',             value: this.eventDescription  || '—' },
            { key: 'mgr',     label: 'Event Manager',                 value: this.eventManagerName  || '—' },
            { key: 'parent',  label: 'Parent Event',                  value: this.parentEventName   || '—' },
            { key: 'start',   label: 'Start Date & Time',             value: fmt(this.startDate)          },
            { key: 'end',     label: 'End Date & Time',               value: fmt(this.endDate)            },
            { key: 'refund',  label: 'Cancellation & Refund Deadline',value: this.refundDeadline    || '—' },
            { key: 'venue',   label: 'Venue',                         value: this.venueName_display || '—' },
            { key: 'hotel',   label: 'Hotel Reservation URL',         value: this.hotelLink         || '—' },
            { key: 'website', label: 'Event Website',                 value: this.eventWebsite      || '—' }
        ];
    }
    get reviewTracksWithMeta() {
        return this.tracks.map((t, i) => ({
            ...t,
            displayNum:     i + 1,
            circleStyle:    `background:${TRACK_COLORS[i % TRACK_COLORS.length]};color:#fff`,
            formattedPrice: t.price ? `$${parseFloat(t.price).toFixed(2)}` : '$0.00',
            ticketLabel:    `${t.tickets} ticket${parseInt(t.tickets, 10) !== 1 ? 's' : ''}`
        }));
    }
    get trackCount() { return this.tracks.length; }

    // ── Publish ───────────────────────────────────────────────────────────────
    /**
     * Called when the user clicks "Publish Event" on the Review step (Step 3).
     *
     * Sequence:
     *   1. createVenue  (already done if user created a new venue via modal)
     *   2. createEvent  → returns eventId
     *   3. createCampaign(eventId, input) → returns { campaignId, campaignName }
     *   4. createTracks(eventId, tracks)
     *   5. Advance to Step 4 (Success)
     */
    async handlePublish() {
        this.isLoading    = true;
        this.saveError    = '';
        this.asanaTaskUrl = '';
        this.asanaError   = '';
        try {
            // ── CLIENT-SIDE DIAGNOSTIC ────────────────────────────────────────
            console.log('=== handlePublish: JS tracked values ===');
            console.log('eventName:',       this.eventName);
            console.log('eventType:',       this.eventType);
            console.log('eventStatus:',     this.eventStatus);
            console.log('eventDescription:', this.eventDescription);
            console.log('theme:',           this.theme);
            console.log('eventManagerId:',  this.eventManagerId);
            console.log('parentEventId:',   this.parentEventId);
            console.log('startDate:',       this.startDate);
            console.log('endDate:',         this.endDate);
            console.log('refundDeadline:',  this.refundDeadline);
            console.log('venueId:',         this.venueId);
            console.log('hotelLink:',       this.hotelLink);
            console.log('eventWebsite:',    this.eventWebsite);
            console.log('tracks:',          JSON.stringify(this.tracks));
            // ─────────────────────────────────────────────────────────────────

            const eventInput = {
                name:                this.eventName,
                eventType:           this.eventType,
                eventStatus:         this.eventStatus,
                eventManagerId:      this.eventManagerId      || null,
                parentEventId:       this.parentEventId       || null,
                startDate:           this.startDate           || null,
                endDate:             this.endDate             || null,
                refundDeadline:      this.refundDeadline      || null,
                venueId:             this.venueId             || null,
                hotelReservationUrl: this.hotelLink           || null,
                eventWebsite:        this.eventWebsite        || null,
                eventDescription:    this.eventDescription    || null,
                theme:               this.theme               || null,
            };
            console.log('=== eventInput being sent to Apex ===', JSON.stringify(eventInput));

            // ── PRE-FLIGHT SAFETY CHECK ─────────────────────────────────────────
            // eventStatus is a hardcoded constant (never touched by any input
            // field) — if it isn't 'Active' here, this component's tracked state
            // has been lost or corrupted (e.g. stale instance from a previous
            // page load, multiple wizard instances on the page). Refuse to
            // publish a broken record instead of silently saving one with blank
            // fields; the Apex layer itself has already been verified to persist
            // every field correctly when given real input.
            const missing = [];
            if (!eventInput.name)        missing.push('Event Name');
            if (!eventInput.eventType)   missing.push('Event Type');
            if (!eventInput.eventStatus) missing.push('Event Status');
            if (!eventInput.startDate)   missing.push('Start Date');
            if (!eventInput.endDate)     missing.push('End Date');
            if (missing.length) {
                this.saveError = 'This wizard lost track of the following field(s) before publishing: '
                    + missing.join(', ')
                    + '. Nothing was saved. Please go back to Step 1 in this same browser tab '
                    + '(without refreshing or opening another tab) and re-enter them, then try again.';
                this.isLoading = false;
                return;
            }
            // ─────────────────────────────────────────────────────────────────

            // NOTE: input is sent as a JSON string, not a plain object. This org's
            // Aura ApexActionController has been confirmed (via debug log
            // comparison) to silently drop the contents of complex/wrapper-typed
            // @AuraEnabled parameters — the raw request always contains the
            // correct data, but the Apex method receives an empty instance.
            // Plain String parameters are unaffected, so we serialize client-side
            // and have Apex deserialize server-side to route around it.
            const eventInputJson = JSON.stringify(eventInput);

            // ① Create Event__c
            const eventId = await createEvent({ inputJson: eventInputJson });
            this.publishedEventId = eventId;

            // ② Create Campaign (runs in parallel context but sequentially here
            //    so that the Campaign Description can reference the Event Id)
            const campaignResult = await createCampaign({ eventId, inputJson: eventInputJson });
            this.publishedCampaignId   = campaignResult.campaignId;
            this.publishedCampaignName = campaignResult.campaignName;

            // ③ Create Track__c children
            const trackInputs = this.tracks.map(t => ({
                name:            t.name,
                description:     t.description    || null,
                ticketPrice:     t.price    ? parseFloat(t.price)   : null,
                numberOfTickets: t.tickets  ? parseFloat(t.tickets) : null,
            }));
            await createTracks({ eventId, tracksJson: JSON.stringify(trackInputs) });

            // ④ Open the Form Assembly Asana ticket. The records above are
            //    already committed, so a failure here is shown on the success
            //    screen rather than blocking it.
            try {
                const asana = await createAsanaTicket({ eventId, campaignId: this.publishedCampaignId });
                this.asanaTaskUrl = asana.taskUrl;
            } catch (asanaErr) {
                this.asanaError = asanaErr.body?.message || asanaErr.message || 'Asana ticket could not be created.';
            }

            this.currentStep = 4;

        } catch (err) {
            this.saveError = err.body?.message || err.message || 'An unexpected error occurred.';
        } finally {
            this.isLoading = false;
        }
    }

    // ── Success screen actions ────────────────────────────────────────────────
    /** Opens the newly created Event__c record page. */
    navigateToEvent() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.publishedEventId, objectApiName: 'Event__c', actionName: 'view' }
        });
    }

    /** Copies the Event Id to the clipboard, falling back to execCommand. */
    async copyEventId(e) {
        e.stopPropagation();
        const id = this.publishedEventId;
        try {
            await navigator.clipboard.writeText(id);
        } catch (err) {
            const ta = document.createElement('textarea');
            ta.value = id;
            ta.style.position = 'fixed';
            ta.style.opacity  = '0';
            this.template.querySelector('.success-records').appendChild(ta);
            ta.select();
            document.execCommand('copy');
            ta.remove();
        }
        this.idCopied = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.idCopied = false; }, 2000);
    }

    get copyIdLabel() { return this.idCopied ? '✓ Copied' : '⧉ Copy ID'; }

    // ── Reset ─────────────────────────────────────────────────────────────────
    handleReset() {
        const d = this._defaultDates();
        this.currentStep           = 1;
        this.eventName             = '';
        this.eventType             = '';
        this.eventDescription      = '';
        this.theme                 = '';
        this.eventManagerName      = '';
        this.eventManagerId        = '';
        this.parentEventName       = '';
        this.parentEventId         = '';
        this.startDate             = d.startDate;
        this.endDate               = d.endDate;
        this.refundDeadline        = d.refundDeadline;
        this.venueName_display     = '';
        this.venueId               = '';
        this.hotelLink             = '';
        this.eventWebsite          = '';
        this.errors                = {};
        this.saveError             = '';
        this.publishedEventId      = '';
        this.publishedCampaignId   = '';
        this.publishedCampaignName = '';
        this.asanaTaskUrl          = '';
        this.asanaError            = '';
        this.idCopied              = false;
        this.tracks =[{ id: _nextId++, name: '', price: '', tickets: '1', description: '' }];
    }

    // ── Venue modal ───────────────────────────────────────────────────────────
    openVenueModal()  { this.showVenueModal = true; }
    closeVenueModal() { this.showVenueModal = false; this.venueErrors = {}; this._clearVenueModal(); }
    stopProp(e)       { e.stopPropagation(); }

    handleVenueModalInput(e) { this[e.target.dataset.field] = e.target.value; }

    /**
     * Called when the user clicks "Save Venue" in the modal.
     * Calls createVenue Apex, then:
     *   • Prepends the new venue to the local _allVenues cache
     *   • Sets venueId + venueName_display on the event form
     *   • Closes the modal
     */
    async handleSaveVenue() {
        const errs = {};
        if (!this.venueModalName.trim())     errs.name     = 'Required';
        if (!this.venueModalType)            errs.type     = 'Required';
        if (!this.venueModalAddress1.trim()) errs.address1 = 'Required';
        if (!this.venueModalCity.trim())     errs.city     = 'Required';
        if (!this.venueModalState.trim())    errs.state    = 'Required';
        if (!this.venueModalZip.trim())      errs.zip      = 'Required';
        this.venueErrors = errs;
        if (Object.keys(errs).length) return;

        this.isLoading = true;
        try {
            const venueInput = {
                name:             this.venueModalName,
                venueType:        this.venueModalType,
                streetAddress1:   this.venueModalAddress1,
                streetAddress2:   this.venueModalAddress2    || null,
                city:             this.venueModalCity,
                state:            this.venueModalState,
                postalCode:       this.venueModalZip,
                venueCapacity:    this.venueModalCapacity    || null,
                primaryContactId: this.venueModalContactId   || null,
                notes:            this.venueModalNotes       || null,
            };

            // See handlePublish() for why input is sent as a JSON string rather
            // than a plain object — this org's Aura layer drops complex/wrapper
            // -typed @AuraEnabled parameters.
            const newVenueId = await createVenue({ inputJson: JSON.stringify(venueInput) });

            // Build a subtitle for the new venue identical to what getVenues returns
            let sub = this.venueModalType || '';
            if (this.venueModalCity)  sub += (sub ? ' · ' : '') + this.venueModalCity;
            if (this.venueModalState) sub += ', ' + this.venueModalState;

            // Prepend to local cache so it appears at the top of the dropdown
            this._allVenues = [
                { id: newVenueId, name: this.venueModalName.trim(), subtitle: sub },
                ...this._allVenues
            ];

            // Auto-select the newly created venue on the event form
            this.venueId          = newVenueId;
            this.venueName_display = this.venueModalName.trim();
            this.venueResults     = [];
            this.showVenueModal   = false;
            this._clearVenueModal();

        } catch (err) {
            this.venueErrors = { ...this.venueErrors, save: err.body?.message || err.message };
        } finally {
            this.isLoading = false;
        }
    }

    _clearVenueModal() {
        this.venueModalName        = '';
        this.venueModalType        = '';
        this.venueModalAddress1    = '';
        this.venueModalAddress2    = '';
        this.venueModalCity        = '';
        this.venueModalState       = '';
        this.venueModalZip         = '';
        this.venueModalCapacity    = '';
        this.venueModalContactName = '';
        this.venueModalContactId   = '';
        this.venueModalNotes       = '';
        this.contactResults        = [];
    }
}