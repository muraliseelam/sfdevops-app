import { createElement } from 'lwc';
import InvoiceSummary from 'c/invoiceSummary';
import getSummary from '@salesforce/apex/InvoiceController.getSummary';

jest.mock(
    '@salesforce/apex/InvoiceController.getSummary',
    () => {
        const { createApexTestWireAdapter } = require('@salesforce/sfdx-lwc-jest');
        return { default: createApexTestWireAdapter(jest.fn()) };
    },
    { virtual: true }
);

describe('c-invoice-summary', () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
    });

    it('renders the count and outstanding amount', async () => {
        const el = createElement('c-invoice-summary', { is: InvoiceSummary });
        el.recordId = '001000000000001AAA';
        document.body.appendChild(el);
        getSummary.emit({ outstanding: 150, count: 2 });
        await Promise.resolve();
        expect(el.shadowRoot.querySelector('.count').textContent).toBe('2 invoice(s)');
    });

    it('shows an error when the data cannot load', async () => {
        const el = createElement('c-invoice-summary', { is: InvoiceSummary });
        document.body.appendChild(el);
        getSummary.error();
        await Promise.resolve();
        expect(el.shadowRoot.querySelector('.slds-text-color_error')).not.toBeNull();
    });
});
