using System;
using System.IO;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Web.UI;
using System.Text;
using Rock;
using Rock.Financial;
using Rock.Attribute;
using Rock.Data;
using Rock.Model;
using Rock.Web;
using Rock.Web.Cache;
using Rock.Web.UI;
using Rock.Logging;
using Rock.Web.UI.Controls;
using org.mywell.MyWellGateway;
using org.mywell.MyWellGateway.Model;
using System.Data.Entity;
using Microsoft.AspNet.SignalR;
using System.Threading.Tasks;

namespace RockWeb.Plugins.org_mywell.Gateway
{
    [DisplayName("My Well Gateway Payment Method Import")]
    [Category("My Well > Gateway")]
    [Description("My Well Gateway Payment Method Import.")]

    [BooleanField("Delete Previous Saved Payment Method",
        Key = AttributeKey.DeletePreviousSavedAccount,
        Description = "Should the saved payment method on the previous gateway be deleted?",
        TrueText = "Yes",
        FalseText = "No",
        DefaultBooleanValue = false,
        Order = 2)]

    [BooleanField("Check For Duplicates",
        Key = AttributeKey.CheckForDuplicates,
        Description = "Should the tool check if there is already a saved payment method. If a similar saved payment method already exists, it will be skipped.",
        TrueText = "Yes",
        FalseText = "No",
        DefaultBooleanValue = true,
        Order = 2)]
    public partial class PaymentMethodImport : Rock.Web.UI.RockBlock
    {

        #region Attribute Keys

        /// <summary>
        /// Keys to use for Block Attributes
        /// </summary>
        private static class AttributeKey
        {
            /// <summary>
            /// Deleting the Previous Saved Payment Method
            /// </summary>
            public const string DeletePreviousSavedAccount = "DeletePreviousSavedAccount";

            /// <summary>
            /// Checking for duplicates
            /// </summary>
            public const string CheckForDuplicates = "CheckForDuplicates";
        }
        #endregion

        #region Feilds



        /// <summary>
        /// This holds the reference to the RockMessageHub SignalR Hub context.
        /// </summary>
        private IHubContext _hubContext = GlobalHost.ConnectionManager.GetHubContext<RockMessageHub>();

        /// <summary>
        /// Gets the signal r notification key.
        /// </summary>
        /// <value>
        /// The signal r notification key.
        /// </value>
        public string SignalRNotificationKey
        {
            get
            {
                return string.Format("BulkImport_BlockId:{0}_SessionId:{1}", this.BlockId, Session.SessionID);
            }
        }

        #endregion

        #region Control Methods

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Init" /> event.
        /// </summary>
        /// <param name="e">An <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnInit(EventArgs e)
        {
            base.OnInit(e);

            this.AddConfigurationUpdateTrigger(upnlContent);
        }


        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Load" /> event.
        /// </summary>
        /// <param name="e">The <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);

            if (!Page.IsPostBack)
            {
                RockPage.AddScriptLink("~/Scripts/jquery.signalR-2.2.0.min.js", fingerprint: false);
            }

            imgMyWellLogo.ImageUrl = this.ResolveRockUrl("/Plugins/org_mywell/Assets/MyWellColor.svg");
            lTitle.Text = "Import Payment Method";

            // we want to make sure the My well Gateway will not be part of the drop down list.
            var myWellFinancialGateway = new FinancialGatewayService(new RockContext()).Queryable().Where(x => x.EntityType.Name == "org.mywell.MyWellGateway.MyWellGateway").Select(x => x.EntityTypeId).FirstOrDefault();

            var financialPreviousGatewayCount = fgMigratingFromFinancialGateway.Items.Count;

            // we want to only show the My Well gatweay for the target gateway dropdown
            var financialTargetGatewayCount = fgMigratingToFinancialGateway.Items.Count;

            // go through all the gateways and make sure none of them are the my well gateway.
            // note: an org can have multiple gateways as the My Well gateway so we want to remove all of them
            for (int i = financialPreviousGatewayCount - 1; i >= 0; i--)
            {
                var item = fgMigratingFromFinancialGateway.Items[i];
                var itemValue = item.Value.AsIntegerOrNull();
                var financialGateway = new FinancialGatewayService(new RockContext()).Queryable().Where(x => x.Id == itemValue).FirstOrDefault();

                if (financialGateway != null && financialGateway.EntityTypeId == myWellFinancialGateway)
                {
                    fgMigratingFromFinancialGateway.Items.Remove(item);
                }
            }

            // go through all the gateways and make sure we only show the My Well Gateway for the target gateway dopdown
            // note: an org can have multiple gateways as the My Well gateway so we want to show all of them
            for (int i = financialTargetGatewayCount - 1; i >= 0; i--)
            {
                var item = fgMigratingToFinancialGateway.Items[i];
                var itemValue = item.Value.AsIntegerOrNull();
                var financialGateway = new FinancialGatewayService(new RockContext()).Queryable().Where(x => x.Id == itemValue).FirstOrDefault();

                if (financialGateway != null && financialGateway.EntityTypeId != myWellFinancialGateway)
                {
                    fgMigratingToFinancialGateway.Items.Remove(item);
                }
            }
        }

        #endregion

        #region Events
        /// <summary>
        /// Handles the Click event of the lbImport control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void btnAnotherImport_Click(object sender, EventArgs e)
        {
            var pageReference = CurrentPageReference;
            NavigateToPage(pageReference);

        }


        /// <summary>
        /// Handles the Click event of the lbImport control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void lbImport_Click(object sender, EventArgs e)
        {

            RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Creating Rock Context");


            var rockContext = new RockContext();


            // Get the file imported and make sure its a csv
            var myWellCSVFile = this.Request.MapPath(fuUploader.UploadedContentFilePath);
            RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Getting the File imported and making sure its a csv");
            FileInfo fileInfo = new FileInfo(myWellCSVFile);
            RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Creating a file info object");
            BinaryFileService binaryFileService = new BinaryFileService(rockContext);
            RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Creating Rock Binrary File Service");
            BinaryFile myWellCSVBinaryFile = binaryFileService.Get(fuUploader.BinaryFileId.Value);
            RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Creating My Well CSV Binary File");

            var importedPaymentMethod = new List<PersonPaymentMethod>();
            var errorMessages = new List<string>();


            if (myWellCSVBinaryFile != null && myWellCSVBinaryFile.FileName.EndsWith(".csv"))
            {


                RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Binary File is a CSV");
                var data = myWellCSVBinaryFile.ContentStream.ReadBytesToEnd();
                var csv = System.Text.Encoding.Default.GetString(data);
                RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Retrieved CSV Content");
                csv = csv.Replace("\r\n", "\n");
                var rows = csv.Split('\n');
                var rowId = 1;

                try
                {
                    /*      This is how the CSV should looke like:
                     * 
                     *      lastName = columns[0],
                     *      firstName = columns[1],
                     *      email = columns[2],
                     *      street1 = columns[3],
                     *      street2 = columns[4],
                     *      city = columns[5],
                     *      state = columns[6],
                     *      postalCode = columns[7],
                     *      country = columns[8],
                     *      paymentType = columns[9],
                     *      accountNumberMasked = columns[10],
                     *      creditCardType = columns[11],
                     *      expirationDate = columns[12],
                     *      gatewayPersonIdentifier = columns[13],
                     *      previousGatewayPersonIdentifier = columns[14],
                     *      personAliasId = columns[15]
                     * 
                     */

                    for (int i = 0; i < rows.Count(); i++)
                    {
                        // check to make sure the header has all the correct fields
                        if (i == 0)
                        {
                            RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Check to make sure all headers fields are correct");
                            var header = rows[i].Split(',');
                            string[] expectedHeader = {"lastName", "firstName", "email", "street1", "street2", "city",
                                "state", "postalCode", "country", "paymentType", "accountNumber", "creditCardType", "expirationDate", "gatewayPersonIdentifier", "previousGatewayPersonIdentifier", "personAliasId"};

                            // check if all headers match what we expect
                            if (expectedHeader.Count() == header.Count())
                            {
                                RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: All headers match....");
                                for (int h = 0; h < expectedHeader.Count(); h++)
                                {
                                    RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Additional header check...");
                                    if (header[h] != expectedHeader[h])
                                    {
                                        errorMessages.Add($"Header is not valid. Expected {expectedHeader[h]} in column {h + 1} but received {header[h]}");
                                    }
                                }
                            }
                            else
                            {
                                RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Headers is not valid");
                                var headerText = String.Empty;
                                for (var c = 0; c < expectedHeader.Count(); c++)
                                {
                                    headerText = c == 0 ? expectedHeader[c] : headerText + ", " + expectedHeader[c];
                                }

                                errorMessages.Add($"Header is not valid. Required headers are {headerText} ");
                                break;
                            }


                            // break if there are any errors from the header
                            if (errorMessages.Count > 0)
                            {
                                break;
                            }
                            RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Check Passed");

                            continue;
                        }

                        // if any empty rows then keep going
                        if (rows[i].IsNullOrWhiteSpace())
                        {
                            RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Empty row, skip");
                            continue;
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Start checking each column value");

                        // verify a few columns to make sure the data fields are correct before adding to an object
                        var columns = rows[i].Split(',');

                        RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Checking first name and last name");
                        // First and last name are required
                        if (string.IsNullOrWhiteSpace(columns[0]) || string.IsNullOrEmpty(columns[1]))
                        {
                            errorMessages.Add($"First and Last Name are requied. Missing in row {rowId}");
                            continue;
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Checking if email is valid");
                        // if email is provided make sure its the correct format
                        if (!string.IsNullOrWhiteSpace(columns[2]))
                        {
                            try
                            {
                                var emailAddress = new System.Net.Mail.MailAddress(columns[2]);
                            }
                            catch
                            {
                                errorMessages.Add($"Email address {columns[2]} for {columns[1]} is not valid");
                                continue;
                            }
                        }

                        var emailValue = columns[2].IsNotNullOrWhiteSpace() ? columns[2] : "-";

                        RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Checking address");

                        if (!string.IsNullOrWhiteSpace(columns[3]) && (string.IsNullOrWhiteSpace(columns[5]) || string.IsNullOrWhiteSpace(columns[6]) || string.IsNullOrWhiteSpace(columns[7]) || string.IsNullOrWhiteSpace(columns[8])))
                        {
                            errorMessages.Add($"Address is not valid for {columns[1]} {columns[0]} with email address {emailValue}");
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Checking payment type");
                        // If Payment Type was provided make sure its either CARD or ACH only
                        if (!string.IsNullOrWhiteSpace(columns[9]) && GetCurrentyTypeValueId(columns[9]) == null)
                        {
                            errorMessages.Add($"Payment Type is not valid for {columns[1]} {columns[0]} with email address {emailValue}");
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Checking credit card type");
                        // If Credit Type is Valid
                        if (!string.IsNullOrWhiteSpace(columns[10]) && !string.IsNullOrWhiteSpace(columns[11]) && GetCreditCardTypeValueId(columns[11], columns[10]) == null)
                        {
                            errorMessages.Add($"Credit Card Type is not valid for {columns[1]} {columns[0]} with email address {emailValue}");
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Checking card expiration date");
                        //Expiration Date needs to be in a specific format MM/YY if Payment Type is CARD
                        DateTime expirationDateValue;
                        if (!string.IsNullOrWhiteSpace(columns[10]) && !string.IsNullOrWhiteSpace(columns[12]) && GetCurrentyTypeValueId(columns[9]) == DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.CURRENCY_TYPE_CREDIT_CARD.AsGuid()).Id && !DateTime.TryParseExact(columns[12], "MM/yy", null, 0, out expirationDateValue))
                        {
                            errorMessages.Add($"Expiration Date is not valid for {columns[1]} {columns[0]} with email address {emailValue}");
                        }


                        RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Checking GatewayPersonIdentifier");
                        // GatewayPersonIdentifier is required
                        if (string.IsNullOrWhiteSpace(columns[13]))
                        {
                            errorMessages.Add($"GatewayPersonIdentifier is not valid for {columns[1]} {columns[0]} with email address {emailValue}");
                        }

                        // If person alias id
                        if (string.IsNullOrWhiteSpace(columns[15]))
                        {
                            errorMessages.Add($"Person Alias Id is invalid for {columns[1]} {columns[0]} with email address {emailValue}");
                        }

                        if (errorMessages.Count > 0)
                        {
                            rowId++;
                            continue;
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Creating Schedule Object");

                        var personPaymentMethod = new PersonPaymentMethod
                        {
                            LastName = columns[0],
                            FirstName = columns[1],
                            Email = columns[2],
                            Street1 = columns[3],
                            Street2 = columns[4],
                            City = columns[5],
                            State = columns[6],
                            PostalCode = columns[7],
                            Country = columns[8],
                            PaymentType = columns[9],
                            AccountNumberMasked = columns[10],
                            CreditCardType = columns[11],
                            ExpirationDate = columns[12],
                            GatewayPersonIdentifier = columns[13],
                            PreviousGatewayPersonIdentifier = columns[14],
                            PersonAliasId = columns[15],
                        };

                        RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Schedule Object Created");

                        importedPaymentMethod.Add(personPaymentMethod);

                        RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method Import: Schedule Imported");

                        rowId++;
                    }
                }
                catch (Exception ex)
                {
                    errorMessages.Add("There was an error with the csv file. Please see the Rock Log Exceptions for more details!");
                    LogException(ex);
                    File.Delete(myWellCSVFile);
                }
            }
            else
            {
                errorMessages.Add("File is not a csv file. Please select a valid csv file and try again.");
                File.Delete(myWellCSVFile);
            }

            // if there are errors with the CSV we don't want to import any data and ask the user to fix the errors
            if (errorMessages.Count > 0)
            {
                pnlError.Visible = true;

                var errors = String.Empty;
                for (var i = 0; i < errorMessages.Count; i++)
                {
                    errors = i == 0 ? errorMessages[i] : errors + "<br/>" + errorMessages[i];
                }
                nbWarningMessage.Text = errors;
                pnUploadCSVErrors.Visible = true;
            }
            else
            {
                pnUploadCSVErrors.Visible = false;
                pnlUploadDetails.Visible = false;
                pnlProgress.Visible = true;
                var url = GetCurrentPageUrl();
                lViewImport.Text = string.Format("<a href='{0}' class='btn btn-success'>Import Another File</a>", url);

                var import = new Task(() => { ImportData(importedPaymentMethod); });
                import.Start();

            }

        }

        /// <summary>
        /// Handles the Click event of the lbImport control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        internal void ImportData(List<PersonPaymentMethod> importedPaymentMethod)
        {

            System.Threading.Thread.Sleep(1000);

            var itemCount = 1;
            var successfulImport = 0;
            var deletedSuccessful = 0;
            var skippingSuccessful = 0;
            List<string> errorMessage = new List<string>();
            List<string> warnMessage = new List<string>();


            foreach (var paymentMethod in importedPaymentMethod)
            {

                try
                {
                    WriteProgressMessage(string.Format("Migrating Payment Method {0} of {1}", itemCount, importedPaymentMethod.Count));

                    itemCount++;

                    RockLogger.Log.Information(RockLogDomains.Finance, $"Payment Method Import: importing payment method with previousGatewayPersonIdentifier {paymentMethod.PreviousGatewayPersonIdentifier}");

                    var rockContext = new RockContext();
                    var financialPersonSavedAccountService = new FinancialPersonSavedAccountService(rockContext);


                    var personAliasService = new PersonAliasService(rockContext);
                    var paymentPersonAlias = personAliasService.Get(paymentMethod.PersonAliasId.AsInteger());

                    var migrationFromGatewayId = fgMigratingFromFinancialGateway.SelectedValueAsInt();
                    var migrationToGatewayId = fgMigratingToFinancialGateway.SelectedValueAsInt();
                    var previousFinancialPersonSavedAccount = financialPersonSavedAccountService.Queryable().Where(fp => fp.ReferenceNumber == paymentMethod.PreviousGatewayPersonIdentifier && fp.FinancialGatewayId == migrationFromGatewayId).FirstOrDefault();
                    var migratedFinancialPersonSavedAccount = financialPersonSavedAccountService.Queryable().Where(fp => fp.ReferenceNumber == paymentMethod.GatewayPersonIdentifier && fp.FinancialGatewayId == migrationToGatewayId).FirstOrDefault();
                    var foundSimilarPaymentMethod = financialPersonSavedAccountService.Queryable().Where(fp => fp.PersonAlias.PersonId == paymentPersonAlias.PersonId && fp.FinancialGatewayId == migrationToGatewayId && fp.FinancialPaymentDetail.AccountNumberMasked == paymentMethod.AccountNumberMasked).FirstOrDefault();
                    var checkForDuplicates = GetAttributeValue(AttributeKey.CheckForDuplicates).AsBooleanOrNull() ?? false;

                    if (migratedFinancialPersonSavedAccount == null && previousFinancialPersonSavedAccount == null)
                    {
                        RockLogger.Log.Information(RockLogDomains.Finance, $"Payment Method Import: previousGatewayPersonIdentifier {paymentMethod.PreviousGatewayPersonIdentifier} not found.");
                        string error = string.Format($"Payment Method {paymentMethod.PreviousGatewayPersonIdentifier} not found. <br/>");
                        errorMessage.Add(error);
                        continue;
                    }

                    // check if person already has a similar payment method
                    if (foundSimilarPaymentMethod != null && checkForDuplicates)
                    {
                        // If there was a payment method already imported for the my well gateway, we want to check if this payment method trying to import is used for text to give
                        if (previousFinancialPersonSavedAccount != null && previousFinancialPersonSavedAccount.IsDefault && !foundSimilarPaymentMethod.IsDefault)
                        {
                            foundSimilarPaymentMethod.IsDefault = previousFinancialPersonSavedAccount.IsDefault;
                            rockContext.SaveChanges();
                            string warn = string.Format($"Payment Method {paymentMethod.PreviousGatewayPersonIdentifier} already imported but was updated to be a Text-To-Give payment method. <br/>");
                            warnMessage.Add(warn);
                            skippingSuccessful++;
                        }
                        else
                        {
                            string warn = string.Format($"Payment Method {paymentMethod.PreviousGatewayPersonIdentifier} already imported. <br/>");
                            warnMessage.Add(warn);
                            skippingSuccessful++;
                        }

                    }
                    else if (previousFinancialPersonSavedAccount != null && migratedFinancialPersonSavedAccount == null)
                    {
                        RockLogger.Log.Information(RockLogDomains.Finance, $"Payment Method Import: Importing payment method.");

                        var newFinancialPersonSavedAccount = new FinancialPersonSavedAccount
                        {
                            ReferenceNumber = paymentMethod.GatewayPersonIdentifier,
                            Name = previousFinancialPersonSavedAccount.Name,
                            TransactionCode = paymentMethod.GatewayPersonIdentifier,
                            PersonAliasId = previousFinancialPersonSavedAccount.PersonAliasId,
                            GroupId = previousFinancialPersonSavedAccount.GroupId,
                            FinancialGatewayId = fgMigratingToFinancialGateway.SelectedValueAsId(),
                            GatewayPersonIdentifier = paymentMethod.GatewayPersonIdentifier,
                            IsDefault = previousFinancialPersonSavedAccount.IsDefault,
                            PreferredForeignCurrencyCodeValueId = previousFinancialPersonSavedAccount.PreferredForeignCurrencyCodeValueId,
                            CreatedByPersonAliasId = previousFinancialPersonSavedAccount.CreatedByPersonAliasId,
                        };

                        var newFinancialPaymentDetail = new FinancialPaymentDetail
                        {
                            AccountNumberMasked = paymentMethod.AccountNumberMasked,
                            CurrencyTypeValueId = previousFinancialPersonSavedAccount.FinancialPaymentDetail.CurrencyTypeValueId,
                            CreditCardTypeValueId = previousFinancialPersonSavedAccount.FinancialPaymentDetail.CreditCardTypeValueId,
                            GatewayPersonIdentifier = paymentMethod.GatewayPersonIdentifier,
                            ExpirationMonth = previousFinancialPersonSavedAccount.FinancialPaymentDetail.ExpirationMonth,
                            ExpirationYear = previousFinancialPersonSavedAccount.FinancialPaymentDetail.ExpirationYear,
                            BillingLocationId = previousFinancialPersonSavedAccount.FinancialPaymentDetail.BillingLocationId,
                            NameOnCard = previousFinancialPersonSavedAccount.FinancialPaymentDetail.NameOnCard,
                            CreatedByPersonAliasId = previousFinancialPersonSavedAccount.FinancialPaymentDetail.CreatedByPersonAliasId,
                            ModifiedByPersonAliasId = previousFinancialPersonSavedAccount.FinancialPaymentDetail.ModifiedByPersonAliasId
                        };

                        // rock has a wierd way of storing the payment info of a saved payment method.
                        // It creates a new table entry for it instead of using the payment method of the schedule
                        newFinancialPersonSavedAccount.FinancialPaymentDetail = new FinancialPaymentDetail();
                        newFinancialPersonSavedAccount.FinancialPaymentDetail.AccountNumberMasked = paymentMethod.AccountNumberMasked;
                        newFinancialPersonSavedAccount.FinancialPaymentDetail.CurrencyTypeValueId = previousFinancialPersonSavedAccount.FinancialPaymentDetail.CurrencyTypeValueId;
                        newFinancialPersonSavedAccount.FinancialPaymentDetail.CreditCardTypeValueId = previousFinancialPersonSavedAccount.FinancialPaymentDetail.CreditCardTypeValueId;
                        newFinancialPersonSavedAccount.FinancialPaymentDetail.NameOnCard = previousFinancialPersonSavedAccount.FinancialPaymentDetail.NameOnCard;
                        newFinancialPersonSavedAccount.FinancialPaymentDetail.ExpirationMonth = previousFinancialPersonSavedAccount.FinancialPaymentDetail.ExpirationMonth;
                        newFinancialPersonSavedAccount.FinancialPaymentDetail.ExpirationYear = previousFinancialPersonSavedAccount.FinancialPaymentDetail.ExpirationYear;
                        newFinancialPersonSavedAccount.FinancialPaymentDetail.BillingLocationId = previousFinancialPersonSavedAccount.FinancialPaymentDetail.BillingLocationId;
                        newFinancialPersonSavedAccount.FinancialPaymentDetail.CreatedByPersonAliasId = previousFinancialPersonSavedAccount.FinancialPaymentDetail.CreatedByPersonAliasId;
                        newFinancialPersonSavedAccount.FinancialPaymentDetail.ModifiedByPersonAliasId = previousFinancialPersonSavedAccount.FinancialPaymentDetail.ModifiedByPersonAliasId;
                        newFinancialPersonSavedAccount.FinancialPaymentDetail.GatewayPersonIdentifier = paymentMethod.GatewayPersonIdentifier;

                        financialPersonSavedAccountService.Add(newFinancialPersonSavedAccount);

                        newFinancialPaymentDetail.FinancialPersonSavedAccountId = newFinancialPersonSavedAccount.Id;

                        rockContext.SaveChanges();
                        successfulImport++;

                        RockLogger.Log.Information(RockLogDomains.Finance, $"Payment Method Import: New payment method saved.");

                    }
                    // shouldn't happen but...
                    else if (migratedFinancialPersonSavedAccount != null && previousFinancialPersonSavedAccount == null)
                    {
                        string warn = string.Format($"Person Payment Method {paymentMethod.PreviousGatewayPersonIdentifier} was previously imported. <br/>");
                        warnMessage.Add(warn);
                        skippingSuccessful++;
                    }

                    // If delete payment method attribute is enabled then delete the users previous gateway payment method
                    // check if we can delete
                    var deletePreviousPaymentMethod = GetAttributeValue(AttributeKey.DeletePreviousSavedAccount).AsBooleanOrNull() ?? false;
                    if (deletePreviousPaymentMethod && previousFinancialPersonSavedAccount != null)
                    {
                        string deleteError;
                        if (!financialPersonSavedAccountService.CanDelete(previousFinancialPersonSavedAccount, out deleteError))
                        {
                            //errorMessage.Add(string.Format("Saved new payment method for person alias Id {0} for the My Well Gateway, but could not delete the person's previous saved payment method {1} for previous schedule Id {2}.<br/>", previousSavedAccount.PersonAliasId, schedule.PreviousGatewayPersonIdentifier, previousSchedule.GatewayScheduleId));
                            RockLogger.Log.Information(RockLogDomains.Finance, $"Payment Method Import: previousGatewayPersonIdentifier {paymentMethod.PreviousGatewayPersonIdentifier} can't be deleted");
                            string error = string.Format($"Previous Payment Method {paymentMethod.PreviousGatewayPersonIdentifier} can't be deleted. <br/>");
                            errorMessage.Add(error);
                        }
                        else
                        {
                            RockLogger.Log.Information(RockLogDomains.Finance, $"Payment Method Import: deleting previousGatewayPersonIdentifier {paymentMethod.PreviousGatewayPersonIdentifier}");

                            // creating new context since using the previous one deletes the payment details of the schedule too which we don't want
                            var savedAccountContext = new RockContext();
                            var savedAccountService = new FinancialPersonSavedAccountService(savedAccountContext);

                            var savedAccount = savedAccountService.Get(previousFinancialPersonSavedAccount.Id);
                            savedAccountService.Delete(savedAccount);
                            savedAccountContext.SaveChanges();

                            deletedSuccessful++;

                            // if the payment method was previously imported we want to add it as a successful import right after deleting the previous gateway saved payment method
                            if (migratedFinancialPersonSavedAccount != null)
                            {
                                successfulImport++;
                            }


                            RockLogger.Log.Information(RockLogDomains.Finance, $"Payment Method Import: deleted previousGatewayPersonIdentifier {paymentMethod.PreviousGatewayPersonIdentifier}");
                        }
                    }




                    RockLogger.Log.Information(RockLogDomains.Finance, $"Payment Method Import: Importing {paymentMethod.PreviousGatewayPersonIdentifier} complete");
                }
                catch (Exception ex)
                {
                    string error = string.Format("Person Payment Method {0} failed to import! <br/>", paymentMethod.GatewayPersonIdentifier);
                    errorMessage.Add(error);
                    LogException(ex);
                }
            }

            var warnings = String.Empty;
            if (warnMessage.Count > 0)
            {
                warnMessage.ForEach(x => warnings += x);
                // logs to rock logger
                warnMessage.ForEach(e => RockLogger.Log.Error(RockLogDomains.Finance, e));

                _hubContext.Clients.All.done(this.SignalRNotificationKey,
               string.Format("<p>Successfully imported <strong>{0}</strong> of <strong>{1}</strong> payment methods.</br><p>Successfully deleted <strong>{2}</strong> of <strong>{1}</strong> payment methods.</br><p>Successfully skipped <strong>{3}</strong> of <strong>{1}</strong> payment methods.</br><hr><p><strong>Skipped:</strong></br>{4}</p>", successfulImport, importedPaymentMethod.Count, deletedSuccessful, skippingSuccessful, warnings));

            }
            else
            {
                _hubContext.Clients.All.done(this.SignalRNotificationKey,
                string.Format("<p>Successfully imported <strong>{0}</strong> of <strong>{1}</strong> payment methods.</br><p>Successfully deleted <strong>{2}</strong> of <strong>{1}</strong> payment methods.</br><p>Successfully skipped <strong>{3}</strong> of <strong>{1}</strong> payment methods.</br>", successfulImport, importedPaymentMethod.Count, deletedSuccessful, skippingSuccessful));

            }

            // print out the payment methods that were not imported. These payment methods are in the exception logs.
            if (errorMessage.Count > 0)
            {
                var errors = String.Empty;
                errorMessage.ForEach(x => errors += x);
                WriteErrorMessage(errors);
                // logs to rock logger
                errorMessage.ForEach(e => RockLogger.Log.Error(RockLogDomains.Finance, e));
            }



            RockLogger.Log.Information(RockLogDomains.Finance, "Payment Method import complete");



        }
        #endregion

        #region Internal Methods

        /// <summary>
        /// Gets the CreditCardTypeValueId.
        /// </summary>
        /// <param name="CreditCardTypeValueId">The CreditCardTypeValueId.</param>
        /// <returns></returns>
        private int? GetCreditCardTypeValueId(string creditCardType, string accountNumberMasked)
        {
            // See if we can figure it out from the CC Type (Amex, Visa, etc)
            var creditCardTypeValue = CreditCardPaymentInfo.GetCreditCardTypeFromName(creditCardType);
            if (creditCardTypeValue == null)
            {
                // GetCreditCardTypeFromName should have worked, but just in case, see if we can figure it out from the MaskedCard using RegEx
                creditCardTypeValue = CreditCardPaymentInfo.GetCreditCardTypeFromCreditCardNumber(accountNumberMasked);
                if (creditCardTypeValue == null)
                {
                    return null;
                }
            }
            return creditCardTypeValue.Id;
        }

        /// <summary>
        /// Gets the CurrencyTypeValueId.
        /// </summary>
        /// <param name="CurrencyTypeValueId">The CurrencyTypeValueId.</param>
        /// <returns></returns>
        private int? GetCurrentyTypeValueId(string paymentType)
        {
            if (paymentType == MyWellPaymentType.ACH.ConvertToString().ToUpper())
            {
                return DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.CURRENCY_TYPE_ACH.AsGuid()).Id;
            }
            else if (paymentType == MyWellPaymentType.CARD.ConvertToString().ToUpper())
            {
                return DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.CURRENCY_TYPE_CREDIT_CARD.AsGuid()).Id;
            }
            else
            {
                return null;
            }
        }

        private void WriteProgressMessage(string status)
        {
            _hubContext.Clients.All.receiveNotification(this.SignalRNotificationKey, status);
        }

        private void WriteErrorMessage(string errorText)
        {
            _hubContext.Clients.All.error(this.SignalRNotificationKey, errorText);
        }

        #endregion
    }

    class PersonPaymentMethod
    {
        public string LastName { get; set; }
        public string FirstName { get; set; }
        public string Street1 { get; set; }
        public string Street2 { get; set; }
        public string City { get; set; }
        public string State { get; set; }
        public string PostalCode { get; set; }
        public string Country { get; set; }
        public string Email { get; set; }
        public string PaymentType { get; set; }
        public string AccountNumberMasked { get; set; }
        public string CreditCardType { get; set; }
        public string ExpirationDate { get; set; }
        public string PreviousGatewayPersonIdentifier { get; set; }
        public string GatewayPersonIdentifier { get; set; }
        public string PersonAliasId { get; set; }
    }
}
