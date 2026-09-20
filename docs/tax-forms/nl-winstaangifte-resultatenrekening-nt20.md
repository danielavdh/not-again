# NL — winstaangifte inkomstenbelasting, resultatenrekening

The Dutch equivalent of `SA105_2026.pdf` and `anlage-euer-2025.pdf`, and the source
`db/tax_categories/nl_*.yml` is transcribed from.

**Why this is a text file and not a PDF.** The Netherlands has no boxed paper form. The
winstaangifte is filled in online at Mijn Belastingdienst, and its authoritative definition is the
XBRL taxonomy the return is transmitted in. So the "form" is a schema, and this is its readable
form: every element of the profit and loss, in the order and hierarchy the taxonomy declares, with
the Belastingdienst's own Dutch labels.

## Provenance

    Nederlandse Taxonomie (NT), Intellectual Property of the State of the Netherlands
    Architecture:  nt20
    Version:       20251210
    Release date:  Thu, 08 Jan 2026
    Entrypoint:    bd-rpt-ihz-aangifte-2025.xsd        (inkomstenheffing, aangifte 2025)
    Linkbase:      bd-ihz-aangifte-winst-resultatenrekening-pre.xml
    Package:       NT20_20260720 (SBR Light), from sbr-nl.nl

The full packages are ~1.7 GB and are **gitignored** (`docs/tax-forms/NL/`). Re-download from
sbr-nl.nl if the taxonomy needs re-reading; this extract is what the catalogue is checked against.

## How to read it

Indentation is the taxonomy's own hierarchy. `bd-abstr_*` elements are section headings and carry
no figure. `bd-i_*` elements are the figures — these become catalogue categories, and the element
name is what `export_column` holds. Names ending `*Total` are computed by the return and are not
tagged. `bd-t_*` is a repeating specification block, not a single figure.

---

    
    Verlies- en winstrekening   [bd-abstr_ProfitAndLossTitle]
      Saldo fiscale winstberekening   [bd-i_BalanceProfitCalculationForTaxPurposesFiscal]
      Winstaandeel belastingplichtige in onderneming   [bd-abstr_ProfitShareTaxpayerBusinessCollaborationTitle]
        Aandeel belastingplichtige ondernemingswinst   [bd-i_BusinessProfitTaxpayerPart]
        Winstaandeel ondernemer in samenwerkingsverbanden   [bd-abstr_ProfitShareEntrepeneurBusinessCollaborationTitle]
          Vergoeding voor arbeid belastingplichtige   [bd-i_ProfitShareAllowanceWagesTaxpayerIncomeTax]
          Overige vergoedingen belastingplichtige   [bd-i_ProfitShareAllowanceOtherTaxpayerIncomeTax]
          Verdeling restant winst aan de belastingplichtige   [bd-i_ProfitShareDivisionRemainderAmountTaxpayerIncomeTax]
      Resultaat gewone bedrijfsuitoefening fiscaal   [bd-i_NormalBusinessActivitiesBusinessResultTotalFiscal]
      Bedrijfsopbrengsten   [bd-abstr_BusinessRevenuesTitle]
        Totaal bedrijfsopbrengsten fiscaal   [bd-i_BusinessRevenuesFiscalTotal]
        Netto omzet fiscaal   [bd-i_TurnoverNetFiscal]
        Wijziging voorraad en onderhanden werk fiscaal   [bd-i_StockAndWorkInProgressChangeFiscal]
        Geactiveerde productie eigen bedrijf fiscaal   [bd-i_CapitalizedProductionOwnBusinessFiscal]
        Overige opbrengsten fiscaal   [bd-i_RevenuesOtherFiscal]
      Bedrijfslasten   [bd-abstr_BusinessExpenditureTitle]
        Totaal bedrijfslasten fiscaal   [bd-i_BusinessExpenditureFiscalTotal]
        Kosten grond- en hulpstoffen, uitbesteed werk en dergelijke   [bd-abstr_RawAndAncillaryMaterialsAndOutsourcedWorkTitle]
          Kosten grond- en hulpstoffen, inkoopprijs van de verkopen fiscaal   [bd-i_RawAncillaryMaterialsPurchasePriceSalesFiscal]
          Kosten uitbesteed werk en andere externe kosten fiscaal   [bd-i_OutsourcedWorkCostsAndOtherExternalCostsFiscal]
        Personeelskosten   [bd-abstr_PersonnelCostsTitle]
          Lonen en salarissen fiscaal   [bd-i_WagesSalariesFiscal]
          Arbeidsbeloning fiscale partner   [bd-i_WagesEarnedByPartnerTaxPurposesFiscal]
          Sociale lasten fiscaal   [bd-i_SocialSecurityCostsFiscal]
          Pensioenlasten fiscaal   [bd-i_PensionCostsFiscal]
          Overige personeelskosten fiscaal   [bd-i_PersonnelCostsOtherFiscal]
          Ontvangen uitkeringen en loonsubsidies fiscaal   [bd-i_BenefitsAndWageSubsidiesReceivedFiscal]
        Afschrijvingen   [bd-abstr_DepreciationsTitle]
          Goodwill afschrijvingen fiscaal   [bd-i_GoodwillDepreciationFiscal]
          Overige immateriële vaste activa afschrijvingen   [bd-i_IntangibleFixedAssetsOtherDepreciation]
          Gebouwen en terreinen afschrijvingen fiscaal   [bd-i_BuildingsLandDepreciationFiscal]
          Afschrijving machines en installaties fiscaal   [bd-i_MachineryDepreciationFiscal]
          Andere vaste bedrijfsmiddelen afschrijving   [bd-i_TangibleFixedAssetsOtherDepreciation]
          Afschrijving bedrijfsgebouwen en terreinen   [bd-abstr_CompanyBuildingsDepreciationTitle]
            Afschrijving milieu-bedrijfsmiddelen fiscaal   [bd-i_EnvironmentalBusinessAssetsDepreciation]
            Afschrijving gebouwen in eigen gebruik fiscaal   [bd-i_BuildingsOwnUseDepreciationFiscal]
            Afschrijving gebouwen ter belegging fiscaal   [bd-i_BuildingsForInvestmentPurposesDepreciationFiscal]
            Afschrijving bedrijfsterreinen fiscaal   [bd-i_CompanySitesEtcDepreciationSpecificationAmountFiscal]
          Willekeurige afschrijving op bedrijfsmiddel in Nederland, specificatie   [bd-t_BusinessAssetsRandomDepreciationNetherlandsSpecification]
            Willekeurige afschrijving op bedrijfsmiddel in Nederland omschrijving   [bd-i_BusinessAssetsRandomDepreciationNetherlandsDescription]
            Willekeurige afschrijving op bedrijfsmiddel in Nederland bedrag   [bd-i_BusinessAssetsRandomDepreciationNetherlandsAmount]
            Willekeurige afschrijving op bedrijfsmiddel in Nederland boekwaarde   [bd-i_BusinessAssetsRandomDepreciationNetherlandsBookValue]
        Overige waardeveranderingen van immateriële en materiële vaste activa   [bd-i_TangibleAndIntangibleFixedAssetsOtherValuationChangeAmount]
        Bijzondere waardevermindering van vlottende activa   [bd-i_CurrentAssetsSpecialValuationDecreaseAmount]
        Overige bedrijfskosten   [bd-abstr_BusinessCostsOtherTitle]
          Auto- en transportkosten fiscaal   [bd-i_CarAndTransportCostsFiscal]
          Huisvestingskosten fiscaal   [bd-i_AccommodationCostsFiscal]
          Onderhoud overige materiële vaste activa fiscaal   [bd-i_MaintenanceOtherTangibleFixedAssetsFiscal]
          Verkoopkosten fiscaal   [bd-i_SalesCostsFiscal]
          Andere kosten fiscaal   [bd-i_CostOtherFiscal]
      Financiële baten en lasten   [bd-abstr_BusinessFinancialResultTitle]
        Totaal financiële baten en lasten fiscaal   [bd-i_BusinessFinanciaResultFiscalTotal]
        Opbrengsten overige vorderingen fiscaal   [bd-i_RevenuesOtherReceivablesFiscal]
        Opbrengsten banktegoeden fiscaal   [bd-i_RevenuesBankCreditsFiscal]
        Ontvangen dividend (met uitzondering van deelnemingsdividend) fiscaal   [bd-i_DividendExceptParticipatingInterestDividendFiscal]
        Kwijtscheldingswinst   [bd-i_ProfitDueToDebtRemission]
        Waardeverandering van vorderingen   [bd-i_ReceivablesValuationChangeAmount]
        Waardeverandering van effecten   [bd-i_StockValuationChangeAmount]
        Kosten schulden, rentelasten etc. fiscaal   [bd-i_InterestExpenditureEtcCostsDebtsFiscal]
      Buitengewone resultaten   [bd-abstr_ExtraordinaryBusinessResultsTitle]
        Buitengewone resultaten fiscaal   [bd-i_ExtraordinaryBusinessResultsFiscal]
        Buitengewone bedrijfsbaten   [bd-abstr_ExtraordinaryIncomeBusinessTitle]
          Boekwinst op activa fiscaal   [bd-i_AssetsBookProfitsFiscal]
          Opheffing terugkeerreserve positief fiscaal   [bd-i_ReturnReserveDiscontinuationPositiveFiscal]
          Overige buitengewone baten fiscaal   [bd-i_ExtraordinaryIncomeBusinessOtherFiscal]
        Buitengewone bedrijfslasten   [bd-abstr_ExtraordinaryExpenditureBusinessTitle]
          Afboeking herinvesteringsreserve fiscaal   [bd-i_ReinvestmentReservesWriteDownFiscal]
          Opheffing terugkeerreserve negatief fiscaal   [bd-i_ReturnReserveDiscontinuationNegativeFiscal]
          Boekverlies op activa fiscaal   [bd-i_AssetsBookLossFiscal]
          Overige buitengewone lasten fiscaal   [bd-i_ExtraordinaryExpenditureBusinessOtherFiscal]
      Toelichting Resultatenrekening   [bd-i_ProfitAndLossDescription]
