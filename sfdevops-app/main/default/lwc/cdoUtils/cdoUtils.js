/**
 * Shared helpers for the SF DevOps components: error reduction, toasts, formatting, status
 * badge mapping, record URLs, refresh and polling. A module with no template.
 */
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';
import LOCALE from '@salesforce/i18n/locale';
import TIME_ZONE from '@salesforce/i18n/timeZone';

// ---------------------------------------------------------------------------------------------
// Errors and toasts
// ---------------------------------------------------------------------------------------------

/**
 * Turns an Apex, UI API, JS or string error (or an array of them) into a list of messages.
 * @param {*} errors
 * @returns {string[]}
 */
export function reduceErrors(errors) {
    const list = Array.isArray(errors) ? errors : [errors];
    return list
        .filter((error) => !!error)
        .map((error) => {
            if (typeof error === 'string') {
                return error;
            }
            const body = error.body;
            if (Array.isArray(body)) {
                return body.map((e) => e.message);
            }
            if (body) {
                if (body.pageErrors && body.pageErrors.length) {
                    return body.pageErrors.map((e) => e.message);
                }
                if (body.fieldErrors && Object.keys(body.fieldErrors).length) {
                    return Object.values(body.fieldErrors)
                        .flat()
                        .map((e) => e.message);
                }
                if (body.output && body.output.errors && body.output.errors.length) {
                    return body.output.errors.map((e) => e.message);
                }
                if (typeof body.message === 'string') {
                    return body.message;
                }
            }
            if (typeof error.message === 'string') {
                return error.message;
            }
            return error.statusText;
        })
        .reduce((all, current) => all.concat(current), [])
        .filter((message) => !!message);
}

/** One readable message for an error. */
export function errorMessage(error, fallback = 'Something went wrong.') {
    const messages = reduceErrors(error);
    return messages.length ? messages.join(' ') : fallback;
}

/**
 * Shows a toast from a component.
 * @param {LightningElement} component the component dispatching the event
 * @param {string} title
 * @param {string} message
 * @param {'success'|'error'|'warning'|'info'} variant
 * @param {'dismissible'|'pester'|'sticky'} mode
 */
export function showToast(component, title, message, variant = 'info', mode = 'dismissible') {
    component.dispatchEvent(new ShowToastEvent({ title, message, variant, mode }));
}

/** Shows an error toast; errors stay until dismissed so they can be read and acted on. */
export function showError(component, title, error) {
    showToast(component, title, errorMessage(error), 'error', 'sticky');
}

// ---------------------------------------------------------------------------------------------
// Formatting
// ---------------------------------------------------------------------------------------------

const dateFormat = safeFormatter({ year: 'numeric', month: 'short', day: 'numeric' });
const dateTimeFormat = safeFormatter({
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: 'numeric',
    minute: '2-digit'
});

function safeFormatter(options) {
    try {
        return new Intl.DateTimeFormat(LOCALE, { ...options, timeZone: TIME_ZONE });
    } catch (e) {
        return new Intl.DateTimeFormat(undefined, options);
    }
}

function toDate(value) {
    if (value === null || value === undefined || value === '') {
        return null;
    }
    const d = value instanceof Date ? value : new Date(value);
    return Number.isNaN(d.getTime()) ? null : d;
}

/** "Oct 13, 2026". A date-only string (YYYY-MM-DD) is shown as that calendar day. */
export function formatDate(value) {
    if (typeof value === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(value)) {
        const [y, m, d] = value.split('-').map(Number);
        return new Intl.DateTimeFormat(LOCALE, { year: 'numeric', month: 'short', day: 'numeric', timeZone: 'UTC' }).format(
            new Date(Date.UTC(y, m - 1, d))
        );
    }
    const d = toDate(value);
    return d ? dateFormat.format(d) : '';
}

/** "Oct 13, 2026, 9:42 AM" in the user's time zone. */
export function formatDateTime(value) {
    const d = toDate(value);
    return d ? dateTimeFormat.format(d) : '';
}

/** "just now", "5 min ago", "3 h ago", "2 d ago", else the date. */
export function formatRelative(value) {
    const d = toDate(value);
    if (!d) {
        return '';
    }
    const seconds = Math.round((Date.now() - d.getTime()) / 1000);
    if (seconds < 0) {
        return formatDateTime(d);
    }
    if (seconds < 60) {
        return 'just now';
    }
    if (seconds < 3600) {
        return `${Math.floor(seconds / 60)} min ago`;
    }
    if (seconds < 86400) {
        return `${Math.floor(seconds / 3600)} h ago`;
    }
    if (seconds < 86400 * 14) {
        return `${Math.floor(seconds / 86400)} d ago`;
    }
    return formatDate(d);
}

/**
 * Percent fields hold literal percents (87.5 means 87.5 %), so no multiplication here.
 * @returns {string} "87.5%" or "" when blank
 */
export function formatPercent(value, digits = 1) {
    if (value === null || value === undefined || value === '') {
        return '';
    }
    const n = Number(value);
    if (Number.isNaN(n)) {
        return '';
    }
    return `${n.toFixed(digits).replace(/\.0+$/, '')}%`;
}

/** Hours as "45 min", "3.2 h" or "2.1 d". */
export function formatHours(hours) {
    if (hours === null || hours === undefined || hours === '') {
        return '';
    }
    const h = Number(hours);
    if (Number.isNaN(h)) {
        return '';
    }
    if (h < 1) {
        return `${Math.round(h * 60)} min`;
    }
    if (h < 48) {
        return `${h.toFixed(1).replace(/\.0$/, '')} h`;
    }
    return `${(h / 24).toFixed(1).replace(/\.0$/, '')} d`;
}

/** Picklist API value → label ("In_Review" → "In Review"). */
export function labelOf(value) {
    return value ? String(value).replace(/_/g, ' ') : '';
}

/** "WI-0001, WI-0002" from a list of names, trimmed to max entries. */
export function joinNames(names, max = 5) {
    const list = (names || []).filter(Boolean);
    if (list.length <= max) {
        return list.join(', ');
    }
    return `${list.slice(0, max).join(', ')} +${list.length - max} more`;
}

// ---------------------------------------------------------------------------------------------
// Status → badge
// ---------------------------------------------------------------------------------------------

const THEME_BY_STATUS = {
    success: [
        'Deployed', 'Success', 'Done', 'Approved', 'Passed', 'Pass', 'Merged', 'Released', 'Healthy',
        'Ready', 'Received', 'Committed'
    ],
    error: ['Failed', 'Fail', 'Conflict', 'Blocked', 'Down', 'Rejected', 'Changes_Requested'],
    warning: ['Degraded', 'Queued', 'Pending', 'Requested', 'Removed'],
    info: [
        'Deploying', 'Dispatched', 'Running', 'Promoting', 'In_Review', 'Assembling', 'Releasing',
        'Validating', 'In_Progress'
    ]
};

const THEME_LOOKUP = Object.entries(THEME_BY_STATUS).reduce((map, [theme, statuses]) => {
    statuses.forEach((s) => {
        map[s.toLowerCase()] = theme;
    });
    return map;
}, {});

/** 'success' | 'error' | 'warning' | 'info' | 'neutral' for a status value. */
export function statusVariant(status) {
    if (!status) {
        return 'neutral';
    }
    return THEME_LOOKUP[String(status).replace(/ /g, '_').toLowerCase()] || 'neutral';
}

/** SLDS badge classes for a status value ("slds-badge slds-theme_success"). */
export function statusBadgeClass(status) {
    const variant = statusVariant(status);
    return variant === 'neutral' ? 'slds-badge' : `slds-badge slds-theme_${variant}`;
}

/** Icon name that pairs with a status, so state never relies on color alone. */
export function statusIcon(status) {
    switch (statusVariant(status)) {
        case 'success':
            return 'utility:success';
        case 'error':
            return 'utility:error';
        case 'warning':
            return 'utility:warning';
        case 'info':
            return 'utility:spinner';
        default:
            return 'utility:record';
    }
}

/** Environment health → badge class and label; blank health means nothing deployed yet. */
export function healthBadge(health) {
    if (!health) {
        return { label: 'No deploys yet', className: 'slds-badge slds-badge_lightest' };
    }
    return { label: health, className: statusBadgeClass(health) };
}

/** Decorates a row with label, badge class and icon for its status field. */
export function withStatus(row, field = 'status') {
    const value = row ? row[field] : null;
    return {
        ...row,
        statusLabel: labelOf(value),
        statusClass: statusBadgeClass(value),
        statusIcon: statusIcon(value)
    };
}

// ---------------------------------------------------------------------------------------------
// Navigation, refresh, polling
// ---------------------------------------------------------------------------------------------

/** A Lightning Experience URL for a record, usable as an href. */
export function recordUrl(recordId, objectApiName) {
    if (!recordId) {
        return null;
    }
    return objectApiName ? `/lightning/r/${objectApiName}/${recordId}/view` : `/lightning/r/${recordId}/view`;
}

/** NavigationMixin page reference for a record. */
export function recordPageRef(recordId, objectApiName, actionName = 'view') {
    const attributes = { recordId, actionName };
    if (objectApiName) {
        attributes.objectApiName = objectApiName;
    }
    return { type: 'standard__recordPage', attributes };
}

/** refreshApex on every wired result given; ignores blanks. */
export function refreshAll(...wiredResults) {
    return Promise.all(wiredResults.filter(Boolean).map((result) => refreshApex(result)));
}

/**
 * Calls `tick` every intervalMs until it resolves truthy (done), stop() is called, or
 * maxAttempts is reached (then onTimeout runs). Only one tick runs at a time. A tick that throws
 * stops the poller and is passed to onError.
 * @returns {{start: Function, stop: Function, isRunning: Function}}
 */
export function createPoller(tick, { intervalMs = 5000, maxAttempts = 60, onTimeout, onError } = {}) {
    let timer = null;
    let attempts = 0;
    let busy = false;

    const stop = () => {
        if (timer) {
            clearInterval(timer);
        }
        timer = null;
    };

    const run = async () => {
        if (busy) {
            return;
        }
        busy = true;
        attempts += 1;
        try {
            const done = await tick(attempts);
            if (done) {
                stop();
            } else if (attempts >= maxAttempts) {
                stop();
                if (onTimeout) {
                    onTimeout();
                }
            }
        } catch (e) {
            stop();
            if (onError) {
                onError(e);
            }
        } finally {
            busy = false;
        }
    };

    const start = () => {
        stop();
        attempts = 0;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        timer = setInterval(run, intervalMs);
    };

    return { start, stop, isRunning: () => timer !== null };
}
