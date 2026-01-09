using System;
using System.IO;
using System.Collections.Generic;
using System.ComponentModel;
using System.Linq;
using System.Web.UI;
using Rock;
using Rock.Financial;
using Rock.Data;
using Rock.Model;
using Rock.Web.UI;
using Rock.Logging;
using Microsoft.AspNet.SignalR;
using System.Threading.Tasks;

namespace RockWeb.Plugins.org_mywell.Gateway
{
    [DisplayName("My Well Charge Schedules")]
    [Category("My Well > Gateway")]
    [Description("My Well Charge Schedules.")]

    public partial class ChargeSchedules : Rock.Web.UI.RockBlock
    {

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
            lTitle.Text = "Charge Schedules";

            // we want to make sure the My well Gateway will not be part of the drop down list.
            var myWellFinancialGateway = new FinancialGatewayService(new RockContext()).Queryable().Where(x => x.EntityType.Name == "org.mywell.MyWellGateway.MyWellGateway").Select(x => x.EntityTypeId).FirstOrDefault();

            var financialPreviousGatewayCount = fgMigratingFromFinancialGateway.Items.Count;
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

            RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Creating Rock Context");


            var rockContext = new RockContext();


            // Get the file imported and make sure its a csv
            var myWellCSVFile = this.Request.MapPath(fuUploader.UploadedContentFilePath);
            RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Getting the File imported and making sure its a csv");
            FileInfo fileInfo = new FileInfo(myWellCSVFile);
            RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Creating a file info object");
            BinaryFileService binaryFileService = new BinaryFileService(rockContext);
            RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Creating Rock Binrary File Service");
            BinaryFile myWellCSVBinaryFile = binaryFileService.Get(fuUploader.BinaryFileId.Value);
            RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Creating My Well CSV Binary File");

            var importedScheduleIds = new List<Schedule>();
            var errorMessages = new List<string>();


            if (myWellCSVBinaryFile != null && myWellCSVBinaryFile.FileName.EndsWith(".csv"))
            {


                RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Binary File is a CSV");
                var data = myWellCSVBinaryFile.ContentStream.ReadBytesToEnd();
                var csv = System.Text.Encoding.Default.GetString(data);
                RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Retrieved CSV Content");
                csv = csv.Replace("\r\n", "\n");
                var rows = csv.Split('\n');
                var rowId = 1;

                try
                {
                    /*      This is how the CSV should looke like:
                     * 
                     *      id = columns[0],
                     * 
                     */

                    for (int i = 0; i < rows.Count(); i++)
                    {
                        // check to make sure the header has all the correct fields
                        if (i == 0)
                        {
                            RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Check to make sure all headers fields are correct");
                            var header = rows[i].Split(',');
                            string[] expectedHeader = { "id" };

                            // check if all headers match what we expect
                            if (expectedHeader.Count() == header.Count())
                            {
                                RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: All headers match....");
                                for (int h = 0; h < expectedHeader.Count(); h++)
                                {
                                    RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Additional header check...");
                                    if (header[h] != expectedHeader[h])
                                    {
                                        errorMessages.Add($"Header is not valid. Expected {expectedHeader[h]} in column {h + 1} but received {header[h]}");
                                    }
                                }
                            }
                            else
                            {
                                RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Headers is not valid");
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
                            RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Check Passed");

                            continue;
                        }

                        // if any empty rows then keep going
                        if (rows[i].IsNullOrWhiteSpace())
                        {
                            RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Empty row, skip");
                            continue;
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Start checking each column value");

                        // verify a few columns to make sure the data fields are correct before adding to an object
                        var columns = rows[i].Split(',');

                        RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Checking first name and last name");
                        // First and last name are required
                        if (string.IsNullOrWhiteSpace(columns[0]))
                        {
                            errorMessages.Add($"Schedule Id is missing. Missing in row {rowId}");
                            continue;
                        }


                        if (errorMessages.Count > 0)
                        {
                            rowId++;
                            continue;
                        }

                        RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Creating Schedule Object");

                        var schedule = new Schedule
                        {
                            Id = columns[0]
                        };

                        RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Schedule Object Created");

                        importedScheduleIds.Add(schedule);

                        RockLogger.Log.Information(RockLogDomains.Finance, "Charge Schedule: Schedule Imported");

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

                var import = new Task(() => { ImportData(importedScheduleIds); });
                import.Start();
            }

        }

        /// <summary>
        /// Handles the Click event of the lbImport control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        internal void ImportData(List<Schedule> importedSchedules)
        {

            System.Threading.Thread.Sleep(1000);

            var itemCount = 1;
            var successfulImport = 0;
            List<string> errorMessage = new List<string>();
            List<string> warnMessage = new List<string>();
            List<string> failedSchedules = new List<string>();
            var changedNextBillDate = new Dictionary<string, DateTime>();


            foreach (var schedule in importedSchedules)
            {

                try
                {
                    WriteProgressMessage(string.Format("Charging schedule {0} of {1}", itemCount, importedSchedules.Count));

                    itemCount++;

                    RockLogger.Log.Information(RockLogDomains.Finance, $"Charge Schedule: Trying to charge schedule {schedule.Id}");

                    var migrationFromGatewayId = fgMigratingFromFinancialGateway.SelectedValueAsInt();

                    var rockContext = new RockContext();
                    var financialScheduledTransactionService = new FinancialScheduledTransactionService(rockContext);
                    var financialSchedule = financialScheduledTransactionService.Queryable().Where(fst => fst.GatewayScheduleId == schedule.Id && fst.FinancialGatewayId == migrationFromGatewayId).FirstOrDefault();
                    var gatewayPersonId = String.Empty;


                    if (financialSchedule == null)
                    {
                        RockLogger.Log.Information(RockLogDomains.Finance, $"Charge Schedule: schedule id {schedule.Id} not found with gateway id ${migrationFromGatewayId}");
                        string error = string.Format($"Schedule {schedule.Id} not found. <br/>");
                        errorMessage.Add(error);
                        failedSchedules.Add($"{schedule.Id}<br/>");
                        continue;
                    }

                    if (financialSchedule.FinancialPaymentDetail.GatewayPersonIdentifier.IsNullOrWhiteSpace())
                    {

                        var financialPersonSavedAccountService = new FinancialPersonSavedAccountService(rockContext);
                        var financialPersonSavedAccounts = financialPersonSavedAccountService.Queryable().Where(a => a.PersonAlias.PersonId == financialSchedule.AuthorizedPersonAlias.PersonId).ToList();

                        // Check if a person doesn't already have a saved payment as the schedule payment method
                        // Checking if the gateway of schedule vs saved account is the same
                        // Checking if the currency type of schedule vs saved account is the same
                        // Checking if the last 4 digifts of the account number are the same
                        // Checking if the person id of the schedule and saved account are the same
                        var matchingSavedAccount = financialPersonSavedAccounts.Find(a => a.FinancialPaymentDetail.AccountNumberMasked.Substring(a.FinancialPaymentDetail.AccountNumberMasked.Length - 4) == financialSchedule.FinancialPaymentDetail.AccountNumberMasked.Substring(financialSchedule.FinancialPaymentDetail.AccountNumberMasked.Length - 4) && a.FinancialPaymentDetail.CurrencyTypeValueId == financialSchedule.FinancialPaymentDetail.CurrencyTypeValueId && a.FinancialGatewayId == financialSchedule.FinancialGatewayId);

                        if (matchingSavedAccount != null && matchingSavedAccount.GatewayPersonIdentifier.IsNotNullOrWhiteSpace())
                        {
                            string error = string.Format($"Schedule {schedule.Id} did not have a GatewayPersonIdentifer but found a match with existing saved account {matchingSavedAccount.GatewayPersonIdentifier} ending in {matchingSavedAccount.FinancialPaymentDetail.AccountNumberMasked} for person {financialSchedule.AuthorizedPersonAlias.PersonId} <br/>");
                            errorMessage.Add(error);
                            gatewayPersonId = matchingSavedAccount.GatewayPersonIdentifier;
                        }
                    }
                    else
                    {
                        gatewayPersonId = financialSchedule.FinancialPaymentDetail.GatewayPersonIdentifier;
                    }

                    var gateway = financialSchedule.FinancialGateway.GetGatewayComponent() as IHostedGatewayComponent;
                    string gatewayErrorMessage = string.Empty;

                    var paymentInfo = new ReferencePaymentInfo
                    {
                        FirstName = financialSchedule.AuthorizedPersonAlias.Person.FirstName,
                        LastName = financialSchedule.AuthorizedPersonAlias.Person.LastName,
                        Email = financialSchedule.AuthorizedPersonAlias.Person.Email,
                        Amount = financialSchedule.TotalAmount,
                    };

                    if (financialSchedule.FinancialPaymentDetail.BillingLocationId.HasValue)
                    {
                        paymentInfo.Street1 = financialSchedule.FinancialPaymentDetail.BillingLocation.Street1;
                        paymentInfo.Street2 = financialSchedule.FinancialPaymentDetail.BillingLocation.Street2;
                        paymentInfo.City = financialSchedule.FinancialPaymentDetail.BillingLocation.City;
                        paymentInfo.State = financialSchedule.FinancialPaymentDetail.BillingLocation.State;
                        paymentInfo.PostalCode = financialSchedule.FinancialPaymentDetail.BillingLocation.PostalCode;
                        paymentInfo.Country = financialSchedule.FinancialPaymentDetail.BillingLocation.Country;
                    }

                    // If this is an NMI gateway, we can get the gateway person identifier from the an existing schedule by creating a new one
                    if (gatewayPersonId.IsNullOrWhiteSpace() && financialSchedule.FinancialGateway.EntityType.Name == "Rock.NMI.Gateway")
                    {
                        paymentInfo.TransactionCode = financialSchedule.GatewayScheduleId;

                        gatewayPersonId = gateway.CreateCustomerAccount(financialSchedule.FinancialGateway, paymentInfo, out gatewayErrorMessage);
                    }

                    if (gatewayPersonId.IsNotNullOrWhiteSpace())
                    {

                        paymentInfo.ReferenceNumber = gatewayPersonId;
                        paymentInfo.GatewayPersonIdentifier = gatewayPersonId;

                        int transactionPersonId = financialSchedule.AuthorizedPersonAlias.PersonId;


                        FinancialTransaction financialTransaction = gateway.Charge(financialSchedule.FinancialGateway, paymentInfo, out gatewayErrorMessage);
                        if (financialTransaction == null)
                        {
                            if (gatewayErrorMessage.IsNullOrWhiteSpace())
                            {
                                gatewayErrorMessage = "Unknown Error";
                            }

                            RockLogger.Log.Information(RockLogDomains.Finance, $"Charge Schedule: schedule id {schedule.Id} error creating transaction with gateway ${migrationFromGatewayId}. Error ${gatewayErrorMessage}");
                            string error = string.Format($"Schedule {schedule.Id} error creating transacation. Error: {gatewayErrorMessage}<br/>");
                            errorMessage.Add(error);
                            failedSchedules.Add($"{schedule.Id}<br/>");
                            continue;
                        }

                        financialTransaction.ScheduledTransactionId = financialSchedule.Id;

                        var payments = new List<Payment>();

                        var payment = new Payment
                        {
                            TransactionCode = financialTransaction.TransactionCode,
                            Amount = financialSchedule.TotalAmount,
                            TransactionDateTime = RockDateTime.Now,
                            GatewayScheduleId = financialSchedule.GatewayScheduleId,
                            GatewayPersonIdentifier = gatewayPersonId,
                        };

                        payments.Add(payment);

                        try
                        {
                            var gatewayProcessPaymentsSummary = FinancialScheduledTransactionService.ProcessPayments(financialSchedule.FinancialGateway, "Charged Schedules", payments, string.Empty, null, null, null);

                            string warn = string.Format($"Transaction {financialTransaction.TransactionCode} for Schedule {schedule.Id}: {gatewayProcessPaymentsSummary} <br/>");
                            warnMessage.Add(warn);

                            RockLogger.Log.Information(RockLogDomains.Finance, $"Charged Schedule: Schedule {schedule.Id} charge complete");

                            successfulImport++;
                        }
                        catch (Exception ex)
                        {
                            string error = string.Format("Schedule {0} with transaction {1} failed to store in rock! <br/>", schedule.Id, financialTransaction.TransactionCode);
                            errorMessage.Add(error);
                            LogException(ex);
                            failedSchedules.Add($"{schedule.Id}<br/>");
                            continue;
                        }
                    }
                    else
                    {
                        RockLogger.Log.Information(RockLogDomains.Finance, $"Charge Schedule: schedule id {schedule.Id} does not have a GatewayPersonIdentifier ${migrationFromGatewayId}");
                        string error = string.Format($"Schedule {schedule.Id} does not have a GatewayPersonIdentifer. <br/>");
                        errorMessage.Add(error);
                        failedSchedules.Add($"{schedule.Id}<br/>");
                        continue;
                    }




                }
                catch (Exception ex)
                {
                    string error = string.Format("Schedule {0} failed to charge! <br/>", schedule.Id);
                    errorMessage.Add(error);
                    failedSchedules.Add($"{schedule.Id}<br/>");
                    LogException(ex);
                    continue;
                }
            }

            var warnings = String.Empty;

            var failedScheduleIds = String.Empty;
            if (failedSchedules.Count > 0)
            {
                failedSchedules.ForEach(x => failedScheduleIds += x);
            }

            if (warnMessage.Count > 0)
            {

                if (failedSchedules.Count == 0)
                {
                    failedScheduleIds = "There were no schedules that failed to charge";
                }
                warnMessage.ForEach(x => warnings += x);
                // logs to rock logger
                warnMessage.ForEach(e => RockLogger.Log.Error(RockLogDomains.Finance, e));

                _hubContext.Clients.All.done(this.SignalRNotificationKey,
               string.Format("<p>Successfully charged <strong>{0}</strong> of <strong>{1}</strong> schedules.</p></br><hr><p><strong>Added Transactions to Rock:</strong></br>{2}</br><hr></p><p><strong>Failed Schedules:</strong></br>{3}</br></p>", successfulImport, importedSchedules.Count, warnings, failedScheduleIds));

            }
            else
            {
                _hubContext.Clients.All.done(this.SignalRNotificationKey,
                string.Format("<p>Successfully charged <strong>{0}</strong> of <strong>{1}</strong> schedules.</br></p></br><hr><p>Failed Schedules:</br>{2}</br>", successfulImport, importedSchedules.Count, failedScheduleIds));

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


            RockLogger.Log.Information(RockLogDomains.Finance, string.Format("<p>Successfully charged <strong>{0}</strong> of <strong>{1}</strong> schedules.</p></br><hr><p><strong>Added Transactions to Rock:</strong></br>{2}</br><hr></p><p><strong>Failed Schedules:</strong></br>{3}</br></p>", successfulImport, importedSchedules.Count, warnings, failedScheduleIds));


        }
        #endregion


        private void WriteProgressMessage(string status)
        {
            _hubContext.Clients.All.receiveNotification(this.SignalRNotificationKey, status);
        }

        private void WriteErrorMessage(string errorText)
        {
            _hubContext.Clients.All.error(this.SignalRNotificationKey, errorText);
        }


    }

    class Schedule
    {
        public string Id { get; set; }
    }
}
