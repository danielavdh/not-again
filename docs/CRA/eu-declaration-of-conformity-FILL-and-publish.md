# EU Declaration of Conformity

Structure specified by **Annex V** of Regulation (EU) 2024/2847, drawn up per **Article 28**.
Also carries the declared support period (Article 13(8)).

You only need this, if you are charging people for doing their books on your installation. If so, log in as sudo, fill the form, sign and upload it as a pdf on the legal page.

## Fill in and convert to PDF

---

**EU Declaration of Conformity**

Product: **[SERVICE_NAME]**, version/commit: _____________________________

Manufacturer: **[CONTACT_TRADING]** (**[CONTACT_NAME]**), **[CONTACT_STREET]**, **[CONTACT_CITY]**,
**[CONTACT_COUNTRY]**

Contact: **[CONTACT_EMAIL]**

This declaration of conformity is issued under the sole responsibility of the manufacturer. The product described above is in conformity with Regulation (EU) 2024/2847 (Cyber Resilience Act).

**Support period:** [SERVICE_NAME] is supported with security fixes for at least
**5 years** from the date of this installation's initial release. *(The CRA's own floor — only keep 5 if you actually intend to still be maintaining this in 5 years. Change the number if not; the statement matters more than the default.)*

Signed for and on behalf of: _____________________________

Place and date: _____________________________

---

Every bracketed field above is a constant this app already has (`config/initializers/contact.rb`).

