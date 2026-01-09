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
using System.Threading.Tasks;
using Microsoft.AspNet.SignalR;

namespace RockWeb.Plugins.org_mywell.Gateway
{
    [DisplayName("My Well Gateway Schedule Upload Detail")]
    [Category("My Well > Gateway")]
    [Description("My Well Gateway Schedule Upload Details.")]

    [LinkedPage("Schedule Matching Page", "Page used to match schedules to a person and allocate schedule amount to different accounts.", order: 1)]
    public partial class ImportDetail : Rock.Web.UI.RockBlock
    {
        #region Control Methods

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Init" /> event.
        /// </summary>
        /// <param name="e">An <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnInit(EventArgs e)
        {
            base.OnInit(e);

            // If there is an ActivationId we want to show activation metrics only and hide the Import metrics
            var activationId = PageParameter("ActivationId").AsInteger();
            if (activationId > 0)
            {
                hfImportViewMode.Value = "Activation";
                litFrequencyTitle.Text = "<h3 class='mb-4 pull-left'>Activated by Frequency</h3>";
            }
            else
            {
                hfImportViewMode.Value = "Import";
                litFrequencyTitle.Text = "<h3 class='mb-4 pull-left'>Imported by Frequency</h3>";
            }
            hfFrequencyViewMode.Value = "Frequency Total";

            // this event gets fired after block settings are updated. it's nice to repaint the screen if these settings would alter it
            this.BlockUpdated += Block_BlockUpdated;
            this.AddConfigurationUpdateTrigger(upnlContent);
        }

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Load" /> event.
        /// </summary>
        /// <param name="e">The <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);

            // Configure the My Well Portal Button
            var mywellPortalUrl = GlobalAttributesCache.Value("MyWellGatewayPortalURL");
            lbMyWellPortal.Target = "_blank";
            lbMyWellPortal.HRef = mywellPortalUrl;

            RockPage.AddScriptLink("~/Scripts/jquery.signalR-2.2.0.min.js", fingerprint: false);

            var importId = PageParameter("ImportId").AsInteger();
            if (!Page.IsPostBack)
            {
                ShowDetail(importId);
            }

            // Add any attribute controls. 
            // This must be done here regardless of whether it is a postback so that the attribute values will get saved.
            var scheduleImport = new MyWellGatewayScheduleImportService(new RockContext()).Get(importId);

            if (scheduleImport == null)
            {
                scheduleImport = new MyWellGatewayScheduleImport();
            }

            scheduleImport.LoadAttributes();
        }

        /// <summary>
        /// Returns breadcrumbs specific to the block that should be added to navigation
        /// based on the current page reference.  This function is called during the page's
        /// oninit to load any initial breadcrumbs.
        /// </summary>
        /// <param name="pageReference">The <see cref="Rock.Web.PageReference" />.</param>
        /// <returns>
        /// A <see cref="System.Collections.Generic.List{BreadCrumb}" /> of block related <see cref="Rock.Web.UI.BreadCrumb">BreadCrumbs</see>.
        /// </returns>
        public override List<BreadCrumb> GetBreadCrumbs(PageReference pageReference)
        {
            var breadCrumbs = new List<BreadCrumb>();

            int? importId = PageParameter(pageReference, "ImportId").AsIntegerOrNull();
            if (importId != null)
            {
                string scheduleImportName = new MyWellGatewayScheduleImportService(new RockContext())
                    .Queryable().Where(b => b.Id == importId.Value)
                    .Select(b => b.Name)
                    .FirstOrDefault();

                if (!string.IsNullOrWhiteSpace(scheduleImportName))
                {
                    breadCrumbs.Add(new BreadCrumb(scheduleImportName, pageReference));
                }
                else
                {
                    breadCrumbs.Add(new BreadCrumb("New Upload", pageReference));
                }
            }
            else
            {
                // don't show a breadcrumb if we don't have a pageparam to work with
            }

            return breadCrumbs;
        }

        #endregion


        #region Fields

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

        #endregion Fields

        #region Events

        /// <summary>
        /// Handles the Click event of the lbImportLink and pnlNavigation control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void btnImportViewMode_Click(object sender, EventArgs e)
        {
            string importId = hfImportId.Value;

            // This logic tells us where the person wants to navigate to. Either to see the Import metric
            // or the Activation metrics
            if (sender == lbImportLink)
            {
                hfImportViewMode.Value = "Import";
                var qryParam = new Dictionary<string, string>();
                qryParam.Add("ImportId", importId);
                NavigateToCurrentPage(qryParam);
            }
            else
            {
                hfImportViewMode.Value = "Activation";
                var qryParam = new Dictionary<string, string>();
                qryParam.Add("ImportId", importId);
                qryParam.Add("ActivationId", importId);
                NavigateToCurrentPage(qryParam);
            }

            ShowMetricDetails(GetImport(importId.AsInteger()));
        }

        /// <summary>
        /// Handles the Click event of the btnFrequencyTotal and hfFrequencyViewMode control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void btnFrequencyViewMode_Click(object sender, EventArgs e)
        {
            // If a person clicks on the calendar icon within the import by frequency section, show the total number
            // of schedules activated by frequency otherwise if they click on the dollar sign we know they want
            // to see the total dollar amount activated by frequency
            if (sender == btnFrequencyTotal)
            {
                hfFrequencyViewMode.Value = "Frequency Total";
            }
            else
            {
                hfFrequencyViewMode.Value = "Frequency Dollar Amount";
            }

            int importId = hfImportId.ValueAsInt();

            ShowMetricDetails(GetImport(importId));
        }

        /// <summary>
        /// Handles the Click event of the lbMatch control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void lbMatch_Click(object sender, EventArgs e)
        {
            var qryParam = new Dictionary<string, string>();
            qryParam.Add("ImportId", hfImportId.Value);
            qryParam.Add("Match", "true");
            NavigateToLinkedPage("ScheduleMatchingPage", qryParam);
        }

        /// <summary>
        /// Handles the Click event of the lbImportSchedules_Click control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void lbImportSchedules_Click(object sender, EventArgs e)
        {
            var qryParam = new Dictionary<string, string>();
            qryParam.Add("ImportId", hfImportId.Value);
            qryParam.Add("Match", "false");
            NavigateToLinkedPage("ScheduleMatchingPage", qryParam);
        }

        /// <summary>
        /// Handles the Click event of the lbActivateSchedules control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void lbActivateSchedules_Click(object sender, EventArgs e)
        {

            pnlWarningMessage.Visible = false;
            lbActivateSchedules.Visible = false;
            pnlActivationProgress.Visible = true;

            var import = new Task(() => { ActivateSchedules(); });
            import.Start();
        }

        /// <summary>
        /// Shows the detail.
        /// </summary>
        /// <param name="importId">The import identifier.</param>
        public void ActivateSchedules()
        {
            System.Threading.Thread.Sleep(1000); //Dirty hack to make the other thread go first

            var importId = hfImportId.ValueAsInt();
            var rockContext = new RockContext();
            var myWellScheduleImportQry = new MyWellGatewayScheduleImportService(rockContext).Queryable().Where(x => x.Id == importId);
            var myWellScheduleImport = myWellScheduleImportQry.FirstOrDefault();
            var myWellSchedules = myWellScheduleImportQry.Select(x => x.Schedules).FirstOrDefault().ToList();
            var errorMessages = new List<string>();

            if (myWellSchedules != null)
            {

                // Activated only the imported schedules for the My Well Gateway
                for (int i = 0; i < myWellSchedules.Count(); i++)
                {

                    WriteProgressMessage(string.Format("Activating schedule {0} of {1}", i, myWellSchedules.Count()));
                    try
                    {
                        myWellSchedules[i].FinancialScheduledTransaction.IsActive = true;
                        rockContext.SaveChanges();
                    }
                    catch (Exception ex)
                    {
                        errorMessages.Add($"Failed to Activate Schedule {myWellSchedules[i].GatewayScheduleId}.<br/>");
                        LogException(ex);
                    }
                }

            }
            // If activating a schedule failed. Show the ones that failed. Exception can be found in the Rock Exception Logs 
            if (errorMessages.Count > 0)
            {

                WriteProgressMessage("There were some schedules that didn't activate.");
                WriteErrorMessage(string.Join("<br>", errorMessages));
                return;
            }
            else
            {
                pnSuccessMessage.Visible = true;
                myWellScheduleImport.IsActivated = true;

                // If some schedules activated and the schedules are paritals schedules show the navigation
                if (myWellSchedules != null && errorMessages.Count != myWellSchedules.Count)
                {
                    // Check if partial schedules then show the navigation
                    if (myWellSchedules.Find(x => x.AccountNumberMasked.IsNullOrWhiteSpace()) != null)
                    {
                        pnlNavigation.Visible = true;
                    }
                }
                rockContext.SaveChanges();

                WriteProgressMessage("Finished Activating all schedules!");
            }

        }

        /// <summary>
        /// Handles the Click event of the lbImport control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void lbImport_Click(object sender, EventArgs e)
        {
            pnlUploadDetails.Visible = false;
            pnlProgress.Visible = true;

            var import = new Task(() => { ImportData(); });
            import.Start();
        }

        private void ImportData()
        {
            //System.Threading.Thread.Sleep(1000); //Dirty hack to make the other thread go first

            var rockContext = new RockContext();
            RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Creating Rock Context");

            // Get the file imported and make sure its a csv
            //var myWellCSVFile = this.Request.MapPath(fuUploader.UploadedContentFilePath);
            RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Getting the File imported and making sure its a csv");
            //FileInfo fileInfo = new FileInfo(myWellCSVFile);
            RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Creating a file info object");
            BinaryFileService binaryFileService = new BinaryFileService(rockContext);
            RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Creating Rock Binrary File Service");
            BinaryFile myWellCSVBinaryFile = binaryFileService.Get(fuUploader.BinaryFileId.Value);
            RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Creating My Well CSV Binary File");

            var importedSchedules = new List<Schedule>();
            var errorMessages = new List<string>();

            if (myWellCSVBinaryFile != null && myWellCSVBinaryFile.FileName.EndsWith(".csv"))
            {
                RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Binary File is a CSV");
                var data = myWellCSVBinaryFile.ContentStream.ReadBytesToEnd();
                var csv = System.Text.Encoding.Default.GetString(data);
                RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Retrieved CSV Content");
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
                     *      amount = columns[3],
                     *      frequency = columns[4],
                     *      startDate = columns[5],
                     *      gatewayScheduleId = columns[6],
                     *      street1 = columns[7],
                     *      street2 = columns[8],
                     *      city = columns[9],
                     *      state = columns[10],
                     *      postalCode = columns[11],
                     *      country = columns[12],
                     *      paymentType = columns[13],
                     *      accountNumberMasked = columns[14],
                     *      creditCardType = columns[15],
                     *      expirationDate = columns[16],
                     *      gatewayPersonIdentifier = columns[17],
                     *      previousGatewayScheduleId = columns[18],
                     *      previousGatewayPersonIdentifier = columns[19],
                     *      personId = columns[20],
                     *      accountAllocation = columns[21],
                     * 
                     */

                    for (int i = 0; i < rows.Count(); i++)
                    {
                        WriteProgressMessage(string.Format("Parsing schedule {0} of {1}", rowId, rows.Count()));

                        // check to make sure the header has all the correct fields
                        if (i == 0)
                        {
                            RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Check to make sure all headers fields are correct");
                            var header = rows[i].Split(',');
                            string[] expectedHeader = {"lastName", "firstName", "email", "amount", "frequency", "startDate", "gatewayScheduleId", "street1", "street2", "city",
                                "state", "postalCode", "country", "paymentType", "accountNumber", "creditCardType", "expirationDate", "gatewayPersonIdentifier", "previousGatewayScheduleId", "previousGatewayPersonIdentifier", "personId", "accountAllocation"};

                            // check if all headers match what we expect
                            if (expectedHeader.Count() == header.Count())
                            {
                                RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: All headers match....");
                                for (int h = 0; h < expectedHeader.Count(); h++)
                                {
                                    RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Additional header check...");
                                    if (header[h] != expectedHeader[h])
                                    {
                                        errorMessages.Add($"Header is not valid. Expected {expectedHeader[h]} in column {h + 1} but received {header[h]}");
                                    }
                                }
                            }
                            else
                            {
                                RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Headers is not valid");
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
                            RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Check Passed");

                            continue;
                        }

                        // if any empty rows then keep going
                        if (rows[i].IsNullOrWhiteSpace())
                        {
                            RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Empty row, skip");
                            continue;
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Start checking each column value");

                        // verify a few columns to make sure the data fields are correct before adding to an object
                        var columns = rows[i].Split(',');

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Checking first name and last name");
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

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Checking amount");
                        // Amount is required
                        decimal amountValue;
                        if (string.IsNullOrWhiteSpace(columns[3]) || !Decimal.TryParse(columns[3], out amountValue))
                        {
                            errorMessages.Add($"Amount is not valid for {columns[1]} {columns[0]} with email address {emailValue}");
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Checking frequency");
                        // Frequency is requied
                        BillingFrequency freqencyValue;
                        if (!Enum.TryParse(columns[4], true, out freqencyValue))
                        {
                            errorMessages.Add($"Schedule frequency is not valid for {columns[1]} {columns[0]} with email address {emailValue}");
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Checking start date");
                        // Start Date is required
                        DateTime startDateValue;
                        if (!DateTime.TryParseExact(columns[5], "yyyy-MM-dd", null, 0, out startDateValue))
                        {
                            errorMessages.Add($"Schedule startDate is not valid for {columns[1]} {columns[0]} with email address {emailValue}");
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Checking gateway schedule Id");
                        // GatewaySchedule Id is required
                        if (string.IsNullOrWhiteSpace(columns[6]))
                        {
                            errorMessages.Add($"GatewayScheduleId is missing for {columns[1]} {columns[0]} with email address {emailValue}");
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Checking payment type");
                        // If Payment Type was provided make sure its either CARD or ACH only
                        if (!string.IsNullOrWhiteSpace(columns[13]) && GetCurrentyTypeValueId(columns[13]) == null)
                        {
                            errorMessages.Add($"Payment Type is not valid for {columns[1]} {columns[0]} with email address {emailValue}");
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Checking credit card type");
                        // If Credit Type is Valid
                        if (!string.IsNullOrWhiteSpace(columns[14]) && !string.IsNullOrWhiteSpace(columns[15]) && GetCreditCardTypeValueId(columns[15], columns[14]) == null)
                        {
                            errorMessages.Add($"Credit Card Type is not valid for {columns[1]} {columns[0]} with email address {emailValue}");
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Checking card expiration date");
                        //Expiration Date needs to be in a specific format MM/YY if Payment Type is CARD
                        DateTime expirationDateValue;
                        if (!string.IsNullOrWhiteSpace(columns[14]) && !string.IsNullOrWhiteSpace(columns[16]) && GetCurrentyTypeValueId(columns[13]) == DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.CURRENCY_TYPE_CREDIT_CARD.AsGuid()).Id && !DateTime.TryParseExact(columns[16], "MM/yy", null, 0, out expirationDateValue))
                        {
                            errorMessages.Add($"Expiration Date is not valid for {columns[1]} {columns[0]} with email address {emailValue}");
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Checking GatewayPersonIdentifier");
                        // GatewayPersonIdentifier is required
                        if (string.IsNullOrWhiteSpace(columns[17]))
                        {
                            errorMessages.Add($"GatewayPersonIdentifier is not valid for {columns[1]} {columns[0]} with email address {emailValue}");
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Checking PreviousGatewayScheduleId if Migration from Gateway selected");
                        // If a gateway was selected in the dropdown make sure the previousGatewayScheduleId exists
                        if (fgMigratingFromFinancialGateway.SelectedValueAsInt().HasValue && string.IsNullOrWhiteSpace(columns[18]))
                        {
                            errorMessages.Add($"Since a Financial Gateway was selected below, the PreviousGatewayScheduleId does not exist for {columns[1]} {columns[0]} with email address {emailValue}");
                        }

                        if (errorMessages.Count > 0)
                        {
                            rowId++;
                            continue;
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Creating Schedule Object");

                        int personId;

                        var financialSchedule = new Schedule
                        {
                            LastName = columns[0],
                            FirstName = columns[1],
                            Email = columns[2],
                            Amount = Decimal.Parse(columns[3]),
                            Frequency = freqencyValue,
                            StartDate = startDateValue,
                            GatewayScheduleId = columns[6],
                            Street1 = columns[7],
                            Street2 = columns[8],
                            City = columns[9],
                            State = columns[10],
                            PostalCode = columns[11],
                            Country = columns[12],
                            PaymentType = columns[13],
                            AccountNumberMasked = columns[14],
                            CreditCardType = columns[15],
                            ExpirationDate = columns[16],
                            GatewayPersonIdentifier = columns[17],
                            PreviousGatewayScheduleId = columns[18],
                            PreviousGatewayPersonIdentifier = columns[19],
                            PersonId = Int32.TryParse(columns[20], out personId) ? (int?)personId : null,
                            AccountAllocation = columns[21],
                        };

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Schedule Object Created");

                        importedSchedules.Add(financialSchedule);

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Schedule Imported");

                        rowId++;
                    }
                }
                catch (Exception ex)
                {
                    errorMessages.Add("There was an error with the csv file. Please see the Rock Log Exceptions for more details!");
                    LogException(ex);
                    //File.Delete(myWellCSVFile);
                }
            }
            else
            {
                errorMessages.Add("File is not a csv file. Please select a valid csv file and try again.");
                //File.Delete(myWellCSVFile);
            }

            var imported = 0;
            // if there are errors with the CSV we don't want to import any data and ask the user to fix the errors
            if (errorMessages.Count > 0)
            {
                WriteProgressMessage("Could not parse CSV");
                WriteErrorMessage(string.Join("<br>", errorMessages));
                return;
            }
            else
            {
                RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Reset the Rock Context");

                rockContext = new RockContext();

                RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Declaring the Schedule Import Service");

                var scheduleImportService = new MyWellGatewayScheduleImportService(rockContext);

                RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Declaring the My Well Schedule Import");

                MyWellGatewayScheduleImport scheduleImport = new MyWellGatewayScheduleImport();

                RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Declaring a new My Well Gateway instance");

                MyWellGateway gateway = new MyWellGateway();
                try
                {
                    scheduleImport.Name = tbName.Text;
                    scheduleImport.Status = ImportStatus.Pending;
                    var foundPartial = importedSchedules.Find(x => x.AccountNumberMasked.IsNullOrWhiteSpace());
                    if (foundPartial != null)
                    {
                        scheduleImport.IsPartial = true;
                    }

                    scheduleImport.MigratingFromFinancialGatewayId = fgMigratingFromFinancialGateway.SelectedValueAsInt();
                    scheduleImport.MigratingToFinancialGatewayId = fgMigratingToFinancialGateway.SelectedValueAsInt();

                    scheduleImportService.Add(scheduleImport);
                    rockContext.SaveChanges();

                    foreach (var schedule in importedSchedules)
                    {
                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Defining new gateway schedule object");

                        int? personAliasId = null;
                        if (schedule.PersonId.HasValue)
                        {
                            var personAlias = new PersonAliasService(rockContext).GetPrimaryAliasId(schedule.PersonId.Value);

                            if (personAlias.HasValue)
                            {
                                personAliasId = personAlias.Value;
                            }
                        }

                        var account = new FinancialAccountService(rockContext).Get(schedule.AccountAllocation);

                        MyWellGatewaySchedule gatewaySchedule = new MyWellGatewaySchedule
                        {
                            LastName = schedule.LastName,
                            FirstName = schedule.FirstName,
                            Amount = schedule.Amount,
                            TransactionFrequencyValueId = gateway.GetScheduleTransactionFrequencyDefinedValue(schedule.Frequency.ToString()),
                            StartDate = schedule.StartDate,
                            GatewayScheduleId = schedule.GatewayScheduleId,
                            TransactionCode = schedule.GatewayScheduleId,
                            Street1 = schedule.Street1.IsNotNullOrWhiteSpace() ? schedule.Street1 : null,
                            Street2 = schedule.Street2.IsNotNullOrWhiteSpace() ? schedule.Street2 : null,
                            City = schedule.City.IsNotNullOrWhiteSpace() ? schedule.City : null,
                            State = schedule.State.IsNotNullOrWhiteSpace() ? schedule.State : null,
                            PostalCode = schedule.PostalCode.IsNotNullOrWhiteSpace() ? schedule.PostalCode : null,
                            Country = schedule.Country.IsNotNullOrWhiteSpace() ? schedule.Country : null,
                            Email = schedule.Email.IsNotNullOrWhiteSpace() ? schedule.Email : null,
                            CurrencyTypeValueId = GetCurrentyTypeValueId(schedule.PaymentType),
                            AccountNumberMasked = schedule.AccountNumberMasked.IsNotNullOrWhiteSpace() ? schedule.AccountNumberMasked : null,
                            CreditCardTypeValueId = GetCreditCardTypeValueId(schedule.CreditCardType, schedule.AccountNumberMasked),
                            ExpirationDate = schedule.ExpirationDate.IsNotNullOrWhiteSpace() ? schedule.ExpirationDate : null,
                            GatewayPersonIdentifier = schedule.GatewayPersonIdentifier,
                            PreviousGatewayScheduleId = schedule.PreviousGatewayScheduleId,
                            PreviousGatewayPersonIdentifier = schedule.PreviousGatewayPersonIdentifier,
                            IsImported = false,
                            AuthorizedPersonAliasId = personAliasId,
                            ImportId = scheduleImport.Id,

                        };

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Create Previous Schedule Cancelled Column if Previous Gateway selected");

                        // check if migrating from a previous gateway. If so then we will populate the column 'previousScheduleCancelled' to false since it is default NULL
                        if (fgMigratingFromFinancialGateway.SelectedValueAsInt().HasValue)
                        {
                            gatewaySchedule.PreviousScheduleStatus = true;
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Adding Schedule to List for Import");

                        scheduleImport.Schedules.Add(gatewaySchedule);
                        rockContext.SaveChanges();


                        // if the account is all digits then its just one account
                        if (account != null)
                        {
                            var accountAllocationService = new MyWellGatewayScheduleAccountAllocationService(rockContext);
                            MyWellGatewayScheduleAccountAllocation accountAllocation = new MyWellGatewayScheduleAccountAllocation
                            {
                                FinancialAccountId = account.Id,
                                Amount = schedule.Amount,
                                ScheduleId = gatewaySchedule.Id,
                                ProcessedDateTime = DateTime.Now,
                            };

                            accountAllocationService.Add(accountAllocation);
                            rockContext.SaveChanges();
                        }

                        // otherwise add some logic for multiple accounts here. Maybe we want to do something like a string key pair amount:acount,amount:account
                        imported++;
                        WriteProgressMessage(string.Format("Uploading schedule {0} of {1}", imported, importedSchedules.Count()));
                    }

                    RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Adding Schedule to My Well Table");

                    rockContext.SaveChanges();
                }
                catch (Exception ex)
                {
                    LogException(ex);
                    WriteProgressMessage("Upload Failed!");
                    WriteErrorMessage(ex.Message);
                    return;
                }

                WriteProgressMessage("Finished Uploading CSV");
                _hubContext.Clients.All.done(this.SignalRNotificationKey,
                      string.Format("<p>Successfully uploaded <strong>{1}</strong> of <strong>{0}</strong> schedules from csv.</p>", imported, importedSchedules.Count), scheduleImport.Id.ToString());

            }
        }


        /// <summary>
        /// Handles the Click event of the lbCancel control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void lbViewUpload_Click(object sender, EventArgs e)
        {
            var pageReference = CurrentPageReference;

            RockLogger.Log.Information(RockLogDomains.Finance, "Schedule Import: Adding import id to the page parameter");

            pageReference.Parameters.AddOrReplace("ImportId", hfImportId.Value);

            NavigateToPage(pageReference);

        }

        /// <summary>
        /// Handles the Click event of the lbCancel control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void lbCancel_Click(object sender, EventArgs e)
        {
            int importId = hfImportId.ValueAsInt();
            if (importId != 0)
            {
                ShowMetricDetails(GetImport(importId));
            }
            else
            {
                NavigateToParentPage();
            }
        }

        /// <summary>
        /// Handles the BlockUpdated event of the control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void Block_BlockUpdated(object sender, EventArgs e)
        {
            int importId = hfImportId.ValueAsInt();
            if (importId != 0)
            {
                ShowMetricDetails(GetImport(importId));
            }
            else
            {
                ShowUploadScreen(GetImport(importId));
            }
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
            else if (paymentType == MyWellPaymentType.APPLE_PAY.ConvertToString().ToUpper())
            {
                return DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.CURRENCY_TYPE_APPLE_PAY.AsGuid()).Id;
            }
            else if (paymentType == MyWellPaymentType.GOOGLE_PAY.ConvertToString().ToUpper())
            {
                return DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.CURRENCY_TYPE_ANDROID_PAY.AsGuid()).Id;
            }
            else
            {
                return null;
            }
        }

        /// <summary>
        /// Gets the Import.
        /// </summary>
        /// <param name="importId">The import identifier.</param>
        /// <returns></returns>
        private MyWellGatewayScheduleImport GetImport(int importId, RockContext rockContext = null)
        {
            rockContext = rockContext ?? new RockContext();
            var import = new MyWellGatewayScheduleImportService(rockContext).Get(importId);
            return import;
        }

        /// <summary>
        /// Shows the detail.
        /// </summary>
        /// <param name="importId">The Schedule Import identifier.</param>
        public void ShowDetail(int importId)
        {
            MyWellGatewayScheduleImport import = null;

            if (!importId.Equals(0))
            {
                import = GetImport(importId);
                if (import != null)
                {
                    pdAuditDetails.SetEntity(import, ResolveRockUrl("~"));
                }
            }

            if (import == null)
            {
                import = new MyWellGatewayScheduleImport { Id = 0, Status = ImportStatus.Pending };

                // hide the panel drawer that show created and last modified dates
                pdAuditDetails.Visible = false;
            }

            hfImportId.Value = import.Id.ToString();

            if (import.Id > 0)
            {
                // Logic to see if imported schedules are partial schedules.
                // If import is complete for all schedules and there are partial scheduels (without a payment method) we will enabled the
                // activation status button otherwise hide it. We will only show this when scheudles have been matched and are Active in rock.
                var rockContext = new RockContext();
                var myWellScheduleService = new MyWellGatewayScheduleService(rockContext);
                var myWellImportQry = new MyWellGatewayScheduleImportService(rockContext).Queryable().Where(x => x.Id == importId);
                var myWellScheduleQry = new MyWellGatewayScheduleService(rockContext).Queryable().Where(x => x.ImportId == importId);
                var importSchedules = myWellImportQry.FirstOrDefault();
                var isImported = myWellImportQry.Any(a => a.Status == ImportStatus.Imported);
                var isPartial = myWellImportQry.Any(a => a.Status == ImportStatus.Imported);
                var hasFailedCancellations = myWellScheduleQry.Where(x => x.IsImported == true && x.PreviousScheduleStatus == true).Any();
                var activatedImportSchedules = myWellImportQry.Where(x => x.IsActivated).Select(x => x.Schedules).FirstOrDefault();


                if (activatedImportSchedules != null)
                {
                    if (importSchedules.IsPartial.Value)
                    {
                        pnlNavigation.Visible = true;
                    }
                }
                else
                {
                    if (isImported)
                    {
                        if (import.MigratingFromFinancialGatewayId.IsNullOrZero())
                        {
                            pnlWarningMessage.Visible = true;
                            lbActivateSchedules.Visible = true;
                        }
                    }
                    else
                    {
                        lbMatch.Visible = true;
                    }
                }

                // check if there were any previous scheduels that failed to cancel. If there are shcedules that need to be cancelled show the lbMatch button so we can retry
                if (hasFailedCancellations)
                {
                    lbMatch.Visible = true;
                }

                // If a migrating from financial gateway was specified then change the wording of the import button
                if ((import.MigratingFromFinancialGatewayId.IsNotNullOrZero() && !import.Schedules.All(x => x.IsImported)) || hasFailedCancellations)
                {
                    lbImportSchedules.Visible = true;
                }

                // We also want to enable import button if the schedules have not been improted yet and there is a rock alias id
                var hasAuthorizedPerson = import.Schedules.Where(s => s.AuthorizedPersonAliasId.HasValue).FirstOrDefault();
                if (hasAuthorizedPerson != null && !import.Schedules.All(x => x.IsImported))
                {
                    lbImportSchedules.Visible = true;
                }

                pnlDetails.Visible = true;
                pnlUpload.Visible = false;
                ShowMetricDetails(import);
                lbImport.Visible = false;
            }
            else
            {
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

                pnlDetails.Visible = false;
                pnlUpload.Visible = true;
                ShowUploadScreen(import);
                lbImport.Visible = true;
            }
        }

        /// <summary>
        /// Shows the upload details with the metrics.
        /// </summary>
        /// <param name="import">The import</param>
        private void ShowMetricDetails(MyWellGatewayScheduleImport import)
        {
            SetUploadMode(false);

            if (import != null)
            {
                hfImportId.SetValue(import.Id);
                SetHeadingInfo(import, import.Name);

                // We only care about these on the Imported by frequency metric
                DefinedValueCache[] myWellScheduleFrequency = {
                    DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.TRANSACTION_FREQUENCY_WEEKLY),
                    DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.TRANSACTION_FREQUENCY_BIWEEKLY),
                    DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.TRANSACTION_FREQUENCY_FIRST_AND_FIFTEENTH),
                    DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.TRANSACTION_FREQUENCY_MONTHLY)
                };

                var progressCircle = new StringBuilder();
                var rockContext = new RockContext();
                var myWellScheduleService = new MyWellGatewayScheduleService(rockContext);
                var myWellScheduleQuery = myWellScheduleService.Queryable().Where(a => a.ImportId == import.Id);
                var totalMatchedActivated = 0;
                var totalSchedules = 0;
                var percentComplete = 0;
                var notMatchedActivated = 0;
                var percentIncomplete = 0;
                decimal notMatchedActivatedAmount = 0;
                decimal totalMatchedActivatedAmount = 0;
                decimal totalAmountSchedules = 0;
                var percentAmountComplete = 0;
                var percentAmountIncomplete = 0;
                string typeText = String.Empty;
                string remainderText = String.Empty;

                // first background color is blue for number imported per frequency and second color is green for the amount imported per frequency
                var definedColorClass = new string[] { "bg-blue-100", "bg-green-100" };
                // first 4 are different colors used for the progress circle for number imported per frequency, the last 4 are shades of green for the
                // amount imported per frequency
                string[] definedColors = new string[] { "#ebf8ff", "#ebf8ff", "#009ce3", "#dfeef6", "#f0fff4", "#48bb78", "#48bb78", "#ddf5e7" };

                string colorClass = String.Empty;
                string[] backgroundColor = { };

                // if the view mode is import we will only show the import metrics
                if (hfImportViewMode.Value == "Import")
                {
                    lbImportLink.CssClass = "mywell-link mywell-link-active";
                    lbClaimedLink.CssClass = "mywell-link";

                    totalSchedules = myWellScheduleQuery.Select(a => a.Id).Count();
                    totalMatchedActivated = myWellScheduleQuery.Where(a => a.IsImported).Count();
                    notMatchedActivated = totalSchedules - totalMatchedActivated;
                    var TotalMatchedAmountQry = myWellScheduleQuery.Where(a => a.IsImported).Select(a => a.Amount);
                    totalAmountSchedules = myWellScheduleQuery.Select(a => a.Amount).Sum();

                    if (TotalMatchedAmountQry.Count() > 0)
                    {
                        totalMatchedActivatedAmount = TotalMatchedAmountQry.Sum();
                        notMatchedActivatedAmount = totalAmountSchedules - totalMatchedActivatedAmount;
                    }
                    else
                    {
                        notMatchedActivatedAmount = totalAmountSchedules;
                        totalMatchedActivatedAmount = 0;
                    }

                    percentComplete = (int)Math.Round((double)(100 * totalMatchedActivated) / totalSchedules);
                    percentIncomplete = 100 - percentComplete;
                    percentAmountComplete = (int)Math.Round((double)(100 * Decimal.ToDouble(totalMatchedActivatedAmount)) / Decimal.ToDouble(totalAmountSchedules));
                    percentAmountIncomplete = 100 - percentAmountComplete;
                    typeText = "imported";
                    remainderText = "Awaiting Import";

                    // Find out how many schedules and dollars imported per frequency
                    foreach (DefinedValueCache frequency in myWellScheduleFrequency)
                    {
                        var totalPerFrequency = 0;
                        var importedTotalPerFrequency = 0;
                        var centerProgressText = String.Empty;
                        var percentageImported = 0;

                        if (hfFrequencyViewMode.Value == "Frequency Total")
                        {
                            btnFrequencyDollars.CssClass = "btn btn-xs btn-outline-success btn-outline-disbled";
                            btnFrequencyDollars.Style.Add("border-left-color", "transparent");
                            btnFrequencyTotal.CssClass = "btn btn-xs btn-info";


                            totalPerFrequency = myWellScheduleQuery.Where(x => x.TransactionFrequencyValueId == frequency.Id).Count();
                            importedTotalPerFrequency = myWellScheduleQuery.Where(x => x.TransactionFrequencyValue.Id == frequency.Id && x.IsImported).Count();
                            centerProgressText = importedTotalPerFrequency.ToString();
                            percentageImported = (int)Math.Round((double)(100 * importedTotalPerFrequency) / totalPerFrequency);
                            colorClass = definedColorClass[0];
                            // only set the first 4 characters of the definedColors since we need the blue
                            backgroundColor = definedColors.Take(4).Select(x => x.ToString()).ToArray();
                        }
                        else
                        {
                            btnFrequencyDollars.CssClass = "btn btn-xs btn-success";
                            btnFrequencyTotal.CssClass = "btn btn-xs btn-outline-info btn-outline-disbled";
                            var amounts = myWellScheduleQuery.Where(x => x.TransactionFrequencyValueId == frequency.Id).Select(x => x.Amount).ToList();
                            var amountsImported = myWellScheduleQuery.Where(x => x.TransactionFrequencyValue.Id == frequency.Id && x.IsImported).Select(x => x.Amount).ToList();

                            if (amounts != null)
                            {
                                totalPerFrequency = (int)Math.Round(amounts.Sum());
                            }
                            if (amountsImported != null)
                            {
                                importedTotalPerFrequency = (int)Math.Round(amountsImported.Sum());
                                centerProgressText = String.Format("{0:C0}", importedTotalPerFrequency);
                            }
                            percentageImported = (int)Math.Round((double)(100 * importedTotalPerFrequency) / totalPerFrequency);
                            colorClass = definedColorClass[1];
                            // only set the last 4 characters of the definedColors since we need the green
                            backgroundColor = definedColors.Skip(4).Take(4).Select(x => x.ToString()).ToArray();
                        }

                        progressCircle.AppendFormat(@"
                        <div class='col-sm-6 col-md-3 d-flex justify-content-center'>
                             <div class='{3} pl-2 pr-2 pt-3 pb-3 w-100 mb-4' style='border-radius: 20px;'>
                                <div role ='progressbarcircle' aria-valuenow='{0}' aria-valuemin='0' aria-valuemax='100' style='--value:{0}; --color0:{4}; --color1:{5};--color2:{6};--color3:{7}'>{1}</div>
                                <strong class='mt-2 d-flex justify-content-center' style='font-size: 14px; font-weight: 700; text-transform:uppercase'>{2}</strong>
                            </div>
                        </div>",
                            percentageImported, centerProgressText, getFrequencyTitle(frequency.Value), colorClass, backgroundColor[0], backgroundColor[1], backgroundColor[2], backgroundColor[3]);
                    }
                }
                // otherwise show the activation metrics
                else
                {
                    lbImportLink.CssClass = "mywell-link";
                    lbClaimedLink.CssClass = "mywell-link mywell-link-active";

                    // Check if there was a payment method was added for a schedule 
                    var myWellSchedules = myWellScheduleQuery.Where(x => x.IsImported).ToList();
                    totalSchedules = myWellSchedules.Count();
                    totalAmountSchedules = myWellScheduleQuery.Where(x => x.IsImported).Select(x => x.Amount).DefaultIfEmpty().Sum();

                    foreach (MyWellGatewaySchedule schedule in myWellSchedules)
                    {
                        // Check activated schedules that have a payment method and get the total count
                        if (schedule.ActivatedDateTime.HasValue)
                        {
                            totalMatchedActivated++;
                            totalMatchedActivatedAmount += schedule.Amount;
                        }
                    }
                    notMatchedActivated = totalSchedules - totalMatchedActivated;
                    notMatchedActivatedAmount = totalAmountSchedules - totalMatchedActivatedAmount;
                    percentComplete = (int)Math.Round((double)(100 * totalMatchedActivated) / totalSchedules);
                    percentIncomplete = 100 - percentComplete;
                    percentAmountComplete = (int)Math.Round((double)(100 * Decimal.ToDouble(totalMatchedActivatedAmount)) / Decimal.ToDouble(totalAmountSchedules));
                    percentAmountIncomplete = 100 - percentAmountComplete;
                    typeText = "activated";
                    remainderText = "Unclaimed";

                    foreach (DefinedValueCache frequency in myWellScheduleFrequency)
                    {
                        var totalImportedPerFrequency = 0;
                        var claimedTotalPerFrequency = 0;
                        var centerProgressText = String.Empty;
                        var percentageImported = 0;
                        decimal totalAmountImportedPerFrequency = 0;
                        decimal totalAmountClaimedPerFrequency = 0;
                        var roundedTotalAmountImportedPerFrequency = 0;
                        var mywellSchedulesPerSpecificFrequency = myWellScheduleQuery.Where(x => x.IsImported && x.TransactionFrequencyValueId == frequency.Id).ToList();
                        var amountsImportedPerFrequency = myWellScheduleQuery.Where(x => x.TransactionFrequencyValue.Id == frequency.Id && x.IsImported).Select(x => x.Amount).ToList();

                        foreach (MyWellGatewaySchedule schedule in mywellSchedulesPerSpecificFrequency)
                        {
                            // Check activated schedules that have a payment method and get the total count
                            if (schedule.ActivatedDateTime.HasValue)
                            {
                                claimedTotalPerFrequency++;
                                totalAmountClaimedPerFrequency += schedule.Amount;
                            }
                        }

                        if (hfFrequencyViewMode.Value == "Frequency Total")
                        {
                            btnFrequencyDollars.CssClass = "btn btn-xs btn-outline-success btn-outline-disbled";
                            btnFrequencyTotal.CssClass = "btn btn-xs btn-info ";
                            totalImportedPerFrequency = myWellScheduleQuery.Where(x => x.TransactionFrequencyValueId == frequency.Id && x.IsImported).Count();
                            centerProgressText = claimedTotalPerFrequency.ToString();
                            percentageImported = (int)Math.Round((double)(100 * claimedTotalPerFrequency) / totalImportedPerFrequency);
                            colorClass = definedColorClass[0];
                            // only set the first 4 characters of the definedColors since we need the blue
                            backgroundColor = definedColors.Take(4).Select(x => x.ToString()).ToArray();
                        }
                        else
                        {
                            btnFrequencyDollars.CssClass = "btn btn-xs btn-success";
                            btnFrequencyTotal.CssClass = "btn btn-xs btn-outline-info btn-outline-disbled";
                            centerProgressText = String.Format("{0:C0}", totalAmountClaimedPerFrequency);
                            if (amountsImportedPerFrequency != null)
                            {
                                totalAmountImportedPerFrequency = (int)Math.Round(amountsImportedPerFrequency.Sum());
                            }
                            roundedTotalAmountImportedPerFrequency = (int)Math.Round(totalAmountImportedPerFrequency);
                            var roundedTotalAmountClaimedPerFrequency = (int)Math.Round(totalAmountClaimedPerFrequency);
                            percentageImported = (int)Math.Round((double)(100 * roundedTotalAmountClaimedPerFrequency) / roundedTotalAmountImportedPerFrequency);
                            colorClass = definedColorClass[1];
                            // only set the last 4 characters of the definedColors since we need the green
                            backgroundColor = definedColors.Skip(4).Take(4).Select(x => x.ToString()).ToArray();
                        }

                        progressCircle.AppendFormat(@"
                        <div class='col-sm-6 col-md-3 d-flex justify-content-center'>
                            <div class='{3} pl-2 pr-2 pt-3 pb-3 w-100 mb-4' style='border-radius: 20px;'>
                                <div role ='progressbarcircle' aria-valuenow='{0}' aria-valuemin='0' aria-valuemax='100' style='--value:{0}; --color0:{4}; --color1:{5};--color2:{6};--color3:{7}'>{1}</div>
                                <strong class='mt-2 d-flex justify-content-center' style='font-size: 14px; font-weight: 700; text-transform:uppercase'>{2}</strong>
                            </div>
                        </div>",
                           percentageImported, centerProgressText, getFrequencyTitle(frequency.Value), colorClass, backgroundColor[0], backgroundColor[1], backgroundColor[2], backgroundColor[3]);
                    }
                }

                // show all the progress bar and circles based on our calculations for either the import view or the activation view
                ltSchedulesImported.Text = string.Format(
                    @"<div class='ml-3'><p class='mb-0'><b style='font-size: 20px; font-weight: 700' class='text-blue-500'>{0}</b> of <b style='font-size: 20px; font-weight: 700'>{1}</b> schedules {3}</p>
                        <p class='mb-0 text-gray-500'>{2}% of the import</p></div>", totalMatchedActivated, totalSchedules, percentComplete, typeText);

                ltSchedulesNotImported.Text = string.Format(
                    @"<p style='font-size: 12px;' class='pt-1 text-gray-500'>{2} <b style='font-weight: 700'>{0} - {1}%</b></p>", notMatchedActivated, percentIncomplete, remainderText);

                ltSchedulesNotImportDollarAmount.Text = string.Format(@"<p style='font-size: 12px;' class='pt-1 text-gray-500'>{2} <b style='font-weight: 700'>{0} - {1}%</b></p>",
                    notMatchedActivatedAmount.FormatAsCurrency(), percentAmountIncomplete, remainderText);

                lProgressBar.Text = string.Format(
                    @"<div class='progress mb-0' style='width: 100%;'>
                            <div class='progress-bar progress-bar-info' role='progressbar' aria-valuenow='{0}' aria-valuemin='0' aria-valuemax='100' style='width:{0}%;'></div>
                      </div>", percentComplete);

                ltSchedulesImportDollarAmount.Text = string.Format(
                    @"<div class='ml-3'><p class='mb-0'><b style='font-size: 20px; font-weight: 700' class='text-green-500'>{0}</b> of <b style='font-size: 20px; font-weight: 700'>{1}</b> {3}</p>
                        <p class='mb-0 text-gray-500'>{2}% of the import</p></div>", totalMatchedActivatedAmount.FormatAsCurrency(), totalAmountSchedules.FormatAsCurrency(), percentAmountComplete, typeText);

                lProgressBarDollars.Text = string.Format(
                    @"<div class='progress mb-0' style='width: 100%;'>
                        <div class='bg-green-500 progress-bar progress-bar-info' role='progressbar' aria-valuenow='{0}' aria-valuemin='0' aria-valuemax='100' style='width:{0}%;'></div>
                    </div>", percentAmountComplete);

                lProgressFrequency.Text = progressCircle.ToString();
            }
        }

        /// <summary>
        /// Gets the Frequency Custom Title
        /// </summary>
        /// <param name="frequency">The Schedule Frequency.</param>
        protected string getFrequencyTitle(string frequency)
        {
            if (frequency == DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.TRANSACTION_FREQUENCY_FIRST_AND_FIFTEENTH).Value)
            {
                return "1ST & 15TH";
            }
            if (frequency == DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.TRANSACTION_FREQUENCY_BIWEEKLY).Value)
            {
                return "EVERY 2 WEEKS";
            }
            return frequency;
        }

        /// <summary>
        /// Shows the Upload Screen
        /// </summary>
        /// <param name="import">The import.</param>
        protected void ShowUploadScreen(MyWellGatewayScheduleImport import)
        {
            imgMyWellLogo.ImageUrl = this.ResolveRockUrl("/Plugins/org_mywell/Assets/MyWellColor.svg");

            if (import != null)
            {
                string title = import.Id > 0 ?
                    "Upload Details" :
                    "Upload Schedules";
                lTitle.Text = title.FormatAsHtmlTitle();
                SetUploadMode(true);
            }
        }

        /// <summary>
        /// Sets the heading information.
        /// </summary>
        /// <param name="import">The import.</param>
        /// <param name="title">The title.</param>
        private void SetHeadingInfo(MyWellGatewayScheduleImport import, string title)
        {
            lTitle.Text = title.FormatAsHtmlTitle();
            SetHeadingImportStatus(import.Status);
        }

        /// <summary>
        /// Sets the heading import status.
        /// </summary>
        /// <param name="importStatus">The import status.</param>
        private void SetHeadingImportStatus(ImportStatus importStatus)
        {
            hlStatus.Text = importStatus.ConvertToString();
            switch (importStatus)
            {
                case ImportStatus.Pending:
                    hlStatus.LabelType = LabelType.Warning;
                    break;
                case ImportStatus.Imported:
                    hlStatus.LabelType = LabelType.Default;
                    break;
            }
        }

        /// <summary>
        /// Sets the upload mode.
        /// </summary>
        /// <param name="editable">if set to <c>true</c> [editable].</param>
        private void SetUploadMode(bool editable)
        {
            pnlUploadDetails.Visible = editable;
            fieldsetViewSummary.Visible = !editable;
            this.HideSecondaryBlocks(editable);
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

    class Schedule
    {
        public string LastName { get; set; }
        public string FirstName { get; set; }
        public decimal Amount { get; set; }
        public BillingFrequency Frequency { get; set; }
        public DateTime StartDate { get; set; }
        public string GatewayScheduleId { get; set; }
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
        public string PreviousGatewayScheduleId { get; set; }
        public string PreviousGatewayPersonIdentifier { get; set; }
        public string GatewayPersonIdentifier { get; set; }
        public int? PersonId { get; set; }
        public string AccountAllocation { get; set; }
    }
}
