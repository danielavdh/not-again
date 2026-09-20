# NL — aangifte omzetbelasting (VAT return)

Extracted alongside the winstaangifte while the taxonomy packages were on disk, because VAT is the
next major feature and re-downloading costs 1.7 GB. Nothing reads this yet.

## Provenance

    Nederlandse Taxonomie (NT), Intellectual Property of the State of the Netherlands
    Architecture:  nt20
    Version:       20251210
    Release date:  Thu, 08 Jan 2026
    Entrypoint:    bd-rpt-ob-aangifte-2026.xsd        (omzetbelasting, aangifte 2026)
    Linkbase:      bd-ob-aangifte-pre.xml
    Package:       NT20_20260720 (SBR Light), from sbr-nl.nl

Indentation is the taxonomy's own hierarchy. `bd-abstr_*` are section headings; `bd-i_*` are the
figures. See `nl-winstaangifte-resultatenrekening-nt20.md` for how these files are produced.

## Why this one is worth having early

**It is tier-3 shaped.** Twenty-seven elements, all of them the ledger summed over a period —
exactly the rule the app uses to decide what it may submit. Contrast the E-Bilanz or a SAF-T file,
which want transaction-level detail this app does not hold.

**And it says what the VAT data model has to carry.** Three things, visible in the structure below:

1. **Net and VAT are separate figures, paired per RATE BAND** — algemeen, verlaagd, overige. So a
   posting needs its rate, not just an amount.
2. **A transaction CLASSIFICATION, which a rate cannot supply.** Domestic, reverse charge
   (verlegd), supplies to and from inside and outside the EU. `Leveringen naar landen buiten EU`
   and a domestic zero-rated supply are both 0% and land in different boxes.
3. **Privégebruik has its own pair of boxes** — which is the existing business/private deduction
   split (`deduction_pair_id`) arriving in the VAT return.

`Verschuldigde omzetbelasting` minus `Voorbelasting` is the whole return. Output VAT is a
liability, input VAT an asset — real postings to control accounts, not a percentage annotation.

---

    
    Gegevens omzet en omzetbelasting   [bd-abstr_TurnoverAndVATDataTitle]
      Prestaties binnenland   [bd-abstr_AcquisitionsInlandTitle]
        Omzet leveringen/diensten belast met algemeen tarief   [bd-i_TaxedTurnoverSuppliesServicesGeneralTariff]
        Omzetbelasting leveringen/diensten algemeen tarief   [bd-i_ValueAddedTaxSuppliesServicesGeneralTariff]
        Omzet leveringen/diensten belast met verlaagd tarief   [bd-i_TaxedTurnoverSuppliesServicesReducedTariff]
        Omzetbelasting leveringen/diensten verlaagd tarief   [bd-i_ValueAddedTaxSuppliesServicesReducedTariff]
        Omzet leveringen/diensten belast met overige tarieven   [bd-i_TaxedTurnoverSuppliesServicesOtherRates]
        Omzetbelasting leveringen/diensten overige tarieven   [bd-i_ValueAddedTaxSuppliesServicesOtherRates]
        Omzet privegebruik   [bd-i_TaxedTurnoverPrivateUse]
        Omzetbelasting over privegebruik   [bd-i_ValueAddedTaxPrivateUse]
        Omzet leveringen/diensten belast met nultarief of niet bij u belast   [bd-i_SuppliesServicesNotTaxed]
      Verleggingsregelingen binnenland   [bd-abstr_ReverseChargeSchemesInlandTitle]
        Omzet leveringen/diensten waarbij heffing is verlegd   [bd-i_TurnoverSuppliesServicesByWhichVATTaxationIsTransferred]
        Omzetbelasting leveringen/diensten waarbij heffing is verlegd   [bd-i_ValueAddedTaxSuppliesServicesByWhichVATTaxationIsTransferred]
      Prestaties naar/in het buitenland   [bd-abstr_AcquisitionsToForeignCountriesAcquisitionsAbroadTitle]
        Leveringen naar landen buiten EU   [bd-i_SuppliesToCountriesOutsideTheEC]
        Leveringen naar/diensten in landen binnen EU   [bd-i_SuppliesToCountriesWithinTheEC]
        Installatie/afstandsverkopen binnen de EU   [bd-i_InstallationDistanceSalesWithinTheEC]
      Prestaties uit het buitenland aan u verricht   [bd-abstr_AcquisitionsFromForeignCountriesDoneForYouTitle]
        Omzet belaste leveringen/diensten uit landen buiten de EU   [bd-i_TurnoverFromTaxedSuppliesFromCountriesOutsideTheEC]
        Omzetbelasting leveringen/diensten uit landen buiten de EU   [bd-i_ValueAddedTaxOnSuppliesFromCountriesOutsideTheEC]
        Omzet belaste leveringen/diensten uit landen binnen EU   [bd-i_TurnoverFromTaxedSuppliesFromCountriesWithinTheEC]
        Omzetbelasting leveringen/diensten uit landen binnen EU   [bd-i_ValueAddedTaxOnSuppliesFromCountriesWithinTheEC]
      Voorbelasting en eindtotaal   [bd-abstr_PreVATGrandTotalTitle]
        Verschuldigde omzetbelasting   [bd-i_ValueAddedTaxOwed]
        Voorbelasting   [bd-i_ValueAddedTaxOnInput]
        Totaal te betalen / terug te vragen   [bd-i_ValueAddedTaxOwedToBePaidBack]
