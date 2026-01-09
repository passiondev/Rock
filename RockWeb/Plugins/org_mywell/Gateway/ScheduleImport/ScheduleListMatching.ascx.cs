using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Data.Entity;
using System.Linq;
using System.Web.UI;
using System.Web.UI.WebControls;
using Rock;
using Rock.Attribute;
using Rock.Data;
using Rock.Model;
using Rock.Utility;
using Rock.Web.Cache;
using Rock.Web.UI;
using Rock.Web.UI.Controls;
using org.mywell.MyWellGateway.Model;
using Rock.Web;
using System.Text;
using Microsoft.AspNet.SignalR;
using System.Threading.Tasks;
using Rock.Logging;

namespace RockWeb.Plugins.org_mywell.Gateway
{
    [DisplayName("My Well Gateway Imported Schedule List Matching")]
    [Category("My Well > Gateway")]
    [Description("My Well Gateway Imported Schedule Matching.")]

    [AccountsField(
        "Accounts",
        Key = AttributeKey.Accounts,
        Description = "Select the accounts that schedule amounts can be allocated to. Leave blank to show all accounts",
        IsRequired = false,
        Order = 0)]
    [LinkedPage(
        "Detail Page",
        Key = AttributeKey.DetailPage,
        Description = "Select the page for displaying import details",
        IsRequired = false,
        Order = 1)]

    [BooleanField("Delete Previous Saved Payment Method",
        Key = AttributeKey.DeletePreviousSavedAccount,
        Description = "Should the saved schedule payment method on the previous gateway be deleted? If the schedule is not being used by another schedule it will be deleted and a new one will be created that can be used for the My Well Gateway.",
        TrueText = "Yes",
        FalseText = "No",
        DefaultBooleanValue = false,
        Order = 3)]
    public partial class ScheduleListMatching : RockBlock
    {
        #region Attribute Keys

        /// <summary>
        /// Keys to use for Block Attributes
        /// </summary>
        private static class AttributeKey
        {
            /// <summary>
            /// The accounts
            /// </summary>
            public const string Accounts = "Accounts";

            /// <summary>
            /// The import detail page
            /// </summary>
            public const string DetailPage = "DetailPage";


            /// <summary>
            /// Deleting the Previous Saved Payment Method
            /// </summary>
            public const string DeletePreviousSavedAccount = "DeletePreviousSavedAccount";

        }

        #endregion Attribute Keys

        #region PageParameterKeys

        public static class PageParameterKey
        {
            public const string ImportId = "ImportId";
            public const string ScheduleId = "ScheduleId";
            public const string Match = "Match";
        }

        #endregion PageParameterKeys

        #region Properties

        /// <summary>
        /// The _focus control
        /// </summary>
        private Control _focusControl = null;
        private List<int> _visibleDisplayedAccountIds
        {
            get
            {
                return this.ViewState["_visibleDisplayedAccountIds"] as List<int>;
            }

            set
            {
                this.ViewState["_visibleDisplayedAccountIds"] = value;
            }
        }

        private List<int> _visibleOptionalAccountIds
        {
            get
            {
                return this.ViewState["_visibleOptionalAccountIds"] as List<int>;
            }

            set
            {
                this.ViewState["_visibleOptionalAccountIds"] = value;
            }
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

        #region Base Control Methods

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Init" /> event.
        /// </summary>
        /// <param name="e">An <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnInit(EventArgs e)
        {
            base.OnInit(e);

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

            // initialize DoFadeIn to "0" so it only gets set to "1" when navigating thru schedules
            hfDoFadeIn.Value = "0";

            if (!Page.IsPostBack)
            {
                hfBackNextHistory.Value = string.Empty;
                LoadDropDowns();
                RenderState();
            }
        }

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.PreRender" /> event.
        /// </summary>
        /// <param name="e">An <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnPreRender(EventArgs e)
        {
            if (_focusControl != null)
            {
                _focusControl.Focus();
            }

            base.OnPreRender(e);
        }

        protected void Block_BlockUpdated(object sender, EventArgs e)
        {
            LoadDropDowns();
        }

        #endregion

        #region Methods

        /// <summary>
        /// Shows the controls needed
        /// </summary>
        private void RenderState()
        {
            var importId = PageParameter(PageParameterKey.ImportId).AsInteger();
            var isMatching = PageParameter(PageParameterKey.Match);

            // If a migrating from financial gateway is slected for this import we will import all the schedules and delete the old schedules
            // there is not need for matching since we ill get the previous schedule details
            var scheduleImportServiceQry = new MyWellGatewayScheduleImportService(new RockContext()).Queryable().Where(x => x.Id == importId);
            var hasMigratingFromFinancialGateway = scheduleImportServiceQry.Where(x => x.MigratingFromFinancialGatewayId.HasValue).Any();

            var schedules = scheduleImportServiceQry.Select(x => x.Schedules).FirstOrDefault().ToList();

            // if at least one has a rock alias id then we will auto import
            var rockAliasId = schedules.Find(s => s.AuthorizedPersonAliasId.HasValue);

            if ((hasMigratingFromFinancialGateway || rockAliasId != null) && isMatching == "false")
            {
                RockPage.AddScriptLink("~/Scripts/jquery.signalR-2.2.0.min.js", fingerprint: false);
                pnlView.Visible = false;
                pnlImportFromPreviousGateway.Visible = true;
                ShowImportFromPreviousGateway(importId);
            }
            else
            {
                pnlImportFromPreviousGateway.Visible = false;
                ShowDetail(importId);
            }
        }

        /// <summary>
        /// Loads the drop downs.
        /// </summary>
        public void LoadDropDowns()
        {
            // get accounts that are both allowed by the BlockSettings and also in the personal AccountList setting
            var rockContext = new RockContext();
            var blockAccountGuidList = GetAttributeValue(AttributeKey.Accounts).SplitDelimitedValues().Select(a => a.AsGuid()).ToList();

            string keyPrefix = GetUserPreferenceKeyPrefix();
            var personalAccountGuidList = (this.GetUserPreference(keyPrefix + "account-list") ?? string.Empty).SplitDelimitedValues().Select(a => a.AsGuid()).ToList();

            var accountQry = new FinancialAccountService(rockContext)
                .GetTree()
                .Where(a => a.IsActive);

            // no accounts specified means "all Active"
            if (blockAccountGuidList.Any())
            {
                accountQry = accountQry.Where(a => blockAccountGuidList.Contains(a.Guid));
            }

            if (personalAccountGuidList.Any())
            {
                // if there are person accounts selected, limit accounts to personal accounts
                var selectedAccountQry = accountQry.Where(a => personalAccountGuidList.Contains(a.Guid));

                accountQry = selectedAccountQry;
            }

            _visibleDisplayedAccountIds = new List<int>(accountQry.Select(a => a.Id).ToList());
            _visibleOptionalAccountIds = new List<int>();

            // make the datasource all accounts, but only show the ones that are in _visibleAccountIds or have a non-zero amount
            var allAccountList = new FinancialAccountService(rockContext).Queryable().AsNoTracking().OrderBy(a => a.Order).ThenBy(a => a.Name).ToList();
            rptAccounts.DataSource = allAccountList;
            rptAccounts.DataBind();

            UpdateVisibleAccountBoxes();
        }
        /// <summary>
        /// Shows Import from previous gateway details.
        /// </summary>
        /// <param name="importId">The import identifier.</param>
        public void ShowImportFromPreviousGateway(int importId)
        {
            var rockContext = new RockContext();
            var myWellScheduleImportQry = new MyWellGatewayScheduleImportService(rockContext).Queryable().Where(x => x.Id == importId);
            var myWellScheduleScheduleQry = new MyWellGatewayScheduleService(rockContext).Queryable().Where(x => x.ImportId == importId);
            var hasFailedCancellations = myWellScheduleScheduleQry.Where(x => x.IsImported == true && x.PreviousScheduleStatus == true).Any();

            var targetGateway = myWellScheduleImportQry.Select(x => x.MigratingToFinancialGateway).FirstOrDefault();
            var previousGateway = myWellScheduleImportQry.Select(x => x.MigratingFromFinancialGateway).FirstOrDefault();
            var isImported = myWellScheduleImportQry.Select(x => x.Status == ImportStatus.Imported).FirstOrDefault();

            lImportTitle.Text = "Schedule Import";
            imgMyWellLogo.ImageUrl = this.ResolveRockUrl("/Plugins/org_mywell/Assets/MyWellColor.svg");

            // if schedules have been all imported than show success
            if (!isImported)
            {
                if (previousGateway != null)
                {
                    lPreviousGateway.Text = string.Format("<strong>Cancel Schedules From</strong> {0}", previousGateway.Name);
                    lImportDescription.Text = string.Format("<p>We will import your schedules to rock and stop the schedules with your previous Financial Gateway. Please verify the details below before importing.</p>");

                }
                else
                {
                    lImportDescription.Text = string.Format("<p>You are about to import schedule data into your Rock instance. Please verify the details below before importing.</p>");
                }
                lMigratingToGateway.Text = string.Format("  <strong>Import To</strong> {0}", targetGateway.Name);
            }
            else
            {
                btnImportFromPreviousGateway.Visible = false;
                lImportDescription.Text = "<p>All schedules were imported successfully!</p>";
            }

            if (hasFailedCancellations)
            {
                lFailedCancellationDescription.Text = "<p>There are schedules that failed to cancel with your previous financial gateway. Retry cancelling the schedules below.</p>";
                lFailedCancellationDescription.Visible = true;
                btnCancelSchedules.Visible = true;
            }
        }

        /// <summary>
        /// Gets the user preference key prefix.
        /// </summary>
        /// <returns></returns>
        private string GetUserPreferenceKeyPrefix()
        {
            return string.Format("schedule-matching-{0}-", BlockId);
        }

        /// <summary>
        /// Shows the detail.
        /// </summary>
        /// <param name="importId">The import identifier.</param>
        public void ImportPartialData(int importId, string redirectUrl)
        {
            System.Threading.Thread.Sleep(1000); //Dirty hack to make the other thread go first

            var rockContext = new RockContext();
            var myWellGatewayScheduleQry = new MyWellGatewayScheduleService(rockContext).Queryable().Where(x => x.ImportId == importId);
            var scheduleImport = new MyWellGatewayScheduleImportService(rockContext).Queryable().Where(x => x.Id == importId);
            var myWellFinancialGatewayId = scheduleImport.Select(x => x.MigratingToFinancialGatewayId).FirstOrDefault();

            var schedulesNotImported = myWellGatewayScheduleQry.Where(x => x.IsImported == false).ToList();
            List<string> errorMessage = new List<string>();

            if (schedulesNotImported.Count > 0)
            {
                var itemCount = 1;
                var successfulImport = 0;

                foreach (var schedule in schedulesNotImported)
                {
                    try
                    {
                        var newRockContext = new RockContext();
                        WriteProgressMessage(string.Format("Importing schedule {0} of {1}", itemCount, schedulesNotImported.Count));

                        itemCount++;

                        //Make sure scheduleId doesn't already exist wihtin the my well gateway (in case someone else tries to import)
                        var lookupSchedule = new FinancialScheduledTransactionService(newRockContext).Queryable().Where(x => x.FinancialGatewayId == myWellFinancialGatewayId && x.GatewayScheduleId == schedule.GatewayScheduleId);
                        var alreadyImported = lookupSchedule.Any();

                        if (!alreadyImported)
                        {
                            // Lookup the previous schedule and get the details to match the accounts and authorized personAliasId
                            var financialScheduleTransactionDetailService = new FinancialScheduledTransactionDetailService(newRockContext);
                            var financialPersonSavedAccountService = new FinancialPersonSavedAccountService(newRockContext);
                            var fstService = new FinancialScheduledTransactionService(newRockContext);

                            var month = schedule.ExpirationDate.IsNotNullOrWhiteSpace() ? schedule.ExpirationDate.Split('/')[0].AsIntegerOrNull() : null;
                            var year = schedule.ExpirationDate.IsNotNullOrWhiteSpace() ? schedule.ExpirationDate.Split('/')[1].AsIntegerOrNull() : null;

                            // throw error if the person alias doesn't exist
                            if(schedule.AuthorizedPersonAliasId.HasValue)
                            {
                                var personAlias = new PersonAliasService(newRockContext).Get(schedule.AuthorizedPersonAliasId.Value);
                                if (personAlias == null)
                                {
                                    string error = string.Format("Schedule {0} failed to import with missing person alias id! <br/>", schedule.GatewayScheduleId);
                                    errorMessage.Add(error);
                                    continue;
                                }
                            }
                            else
                            {
                                string error = string.Format("Schedule {0} failed to import with missing person alias id! <br/>", schedule.GatewayScheduleId);
                                errorMessage.Add(error);
                                continue;
                            }

                            // throw error if the account id isn't found
                            if(schedule.AccountAllocation.Count > 0)
                            {
                                var scheduleAccounts = new MyWellGatewayScheduleAccountAllocationService(newRockContext).Queryable().Where(a => a.ScheduleId == schedule.Id).ToList();

                                // get the accounts
                                foreach (var scheduleAccount in scheduleAccounts)
                                {
                                    if (scheduleAccount.FinancialAccount == null)
                                    {
                                        string error = string.Format("Schedule {0} failed to import because of missing account id! <br/>", schedule.GatewayScheduleId);
                                        errorMessage.Add(error);
                                        continue;
                                    }
                                }
                            }
                            else
                            {
                                string error = string.Format("Schedule {0} failed to import because of missing account id! <br/>", schedule.GatewayScheduleId);
                                errorMessage.Add(error);
                                continue;
                            }

                            int? personLocationId = null;

                            var personHome = schedule.AuthorizedPersonAlias.Person.GetHomeLocation();

                            if (personHome != null)
                            {
                                personLocationId = personHome.Id;
                            }

                            try
                            {
                                var financialPaymentDetail = new FinancialPaymentDetail
                                {
                                    AccountNumberMasked = schedule.AccountNumberMasked,
                                    CurrencyTypeValueId = schedule.CurrencyTypeValueId,
                                    CreditCardTypeValueId = schedule.CreditCardTypeValueId,
                                    GatewayPersonIdentifier = schedule.GatewayPersonIdentifier,
                                    ExpirationMonth = month,
                                    ExpirationYear = year,
                                    BillingLocationId = personLocationId,
                                };

                                var financialScheduleTransaction = new FinancialScheduledTransaction
                                {
                                    TransactionCode = schedule.TransactionCode,
                                    FinancialPaymentDetail = financialPaymentDetail,
                                    FinancialGatewayId = myWellFinancialGatewayId,
                                    AuthorizedPersonAliasId = schedule.AuthorizedPersonAliasId.Value,
                                    TransactionFrequencyValueId = schedule.TransactionFrequencyValueId,
                                    GatewayScheduleId = schedule.GatewayScheduleId,
                                    NextPaymentDate = schedule.StartDate,
                                    StartDate = schedule.StartDate,
                                    IsActive = false,
                                    SourceTypeValueId = 10,
                                    TransactionTypeValueId = 53,
                                    Summary = "",
                                    Status = FinancialScheduledTransactionStatus.Active,
                                };

                                var scheduleAccounts = new MyWellGatewayScheduleAccountAllocationService(new RockContext()).Queryable().Where(a => a.ScheduleId == schedule.Id).ToList();


                                // get the accounts
                                foreach (var scheduleAccount in scheduleAccounts)
                                {
                                    var financialScheduleTransactionDetail = new FinancialScheduledTransactionDetail();
                                    financialScheduleTransactionDetail.AccountId = scheduleAccount.FinancialAccountId;
                                    financialScheduleTransactionDetail.Amount = scheduleAccount.Amount;
                                    financialScheduleTransactionDetail.ScheduledTransaction = financialScheduleTransaction;
                                    financialScheduleTransactionDetailService.Add(financialScheduleTransactionDetail);
                                }

                                newRockContext.SaveChanges();

                                // update fields in my well table
                                schedule.IsImported = true;
                                schedule.ProcessedByPersonAliasId = this.CurrentPersonAliasId;
                                schedule.ProcessedDateTime = financialScheduleTransaction.CreatedDateTime;
                                schedule.FinancialScheduledTransactionId = financialScheduleTransaction.Id;
                                newRockContext.SaveChanges();
                                rockContext.SaveChanges();
                                successfulImport++;

                            }
                            catch (Exception ex)
                            {
                                string error = string.Format("Schedule {0} failed to import! <br/>", schedule.GatewayScheduleId);
                                errorMessage.Add(error);
                                LogException(ex);
                            }
                        }
                        else
                        {
                            string error = string.Format("A schedule of {0} already exists! <br/>", schedule.GatewayScheduleId);
                            errorMessage.Add(error);
                            schedule.ProcessedByPersonAliasId = this.CurrentPersonAliasId;
                            schedule.FinancialScheduledTransactionId = lookupSchedule.FirstOrDefault().Id;
                            schedule.ProcessedDateTime = lookupSchedule.FirstOrDefault().CreatedDateTime;
                            schedule.IsImported = true;
                            rockContext.SaveChanges();
                        }

                    }
                    catch (Exception ex)
                    {
                        string error = string.Format("Schedule {0} failed to import! <br/>", schedule.GatewayScheduleId);
                        errorMessage.Add(error);
                        LogException(ex);
                    }
                }

                _hubContext.Clients.All.done(this.SignalRNotificationKey,
               string.Format("<p>Successfully imported <strong>{0}</strong> of <strong>{1}</strong> schedules.</p>", successfulImport, schedulesNotImported.Count));

                // print out the scheduels that were not imported. These schedules are in the exception logs as weel.
                if (errorMessage.Count > 0)
                {
                    var errors = String.Empty;
                    errorMessage.ForEach(x => errors += x);
                    WriteErrorMessage(errors);
                    // logs to rock logger
                    errorMessage.ForEach(e => RockLogger.Log.Error(RockLogDomains.Finance, e));
                }
            }

            rockContext = new RockContext();

            // check if all are imported then mark this imprt as imported and active
            var importQry = new MyWellGatewayScheduleImportService(rockContext).Queryable().Where(x => x.Id == importId);
            var import = importQry.FirstOrDefault();
            var importSchedulesQry = importQry.Select(x => x.Schedules).FirstOrDefault();

            if (importSchedulesQry != null && importSchedulesQry.All(x => x.IsImported))
            {
                importQry.FirstOrDefault().IsActivated = false;
                importQry.FirstOrDefault().Status = ImportStatus.Imported;
                rockContext.SaveChanges();
            }
        }

        /// <summary>
        /// Shows the detail.
        /// </summary>
        /// <param name="importId">The import identifier.</param>
        public void ImportData(int importId, string redirectUrl)
        {
            System.Threading.Thread.Sleep(1000); //Dirty hack to make the other thread go first

            var rockContext = new RockContext();
            var myWellGatewayScheduleQry = new MyWellGatewayScheduleService(rockContext).Queryable().Where(x => x.ImportId == importId);
            var scheduleImport = new MyWellGatewayScheduleImportService(rockContext).Queryable().Where(x => x.Id == importId);
            var previousGatewayId = scheduleImport.Select(x => x.MigratingFromFinancialGatewayId).FirstOrDefault();
            var myWellFinancialGatewayId = scheduleImport.Select(x => x.MigratingToFinancialGatewayId).FirstOrDefault();

            var schedulesNotImported = myWellGatewayScheduleQry.Where(x => x.IsImported == false).ToList();
            List<string> errorMessage = new List<string>();

            if (schedulesNotImported.Count > 0)
            {
                var itemCount = 1;
                var successfulImport = 0;
                var successfulStopped = 0;

                foreach (var schedule in schedulesNotImported)
                {
                    try
                    {
                        var newRockContext = new RockContext();
                        WriteProgressMessage(string.Format("Importing schedule {0} of {1}", itemCount, schedulesNotImported.Count));

                        itemCount++;

                        //Make sure scheduleId doesn't already exist wihtin the my well gateway (in case someone else tries to import)
                        var lookupSchedule = new FinancialScheduledTransactionService(newRockContext).Queryable().Where(x => x.FinancialGatewayId == myWellFinancialGatewayId && x.GatewayScheduleId == schedule.GatewayScheduleId);
                        var alreadyImported = lookupSchedule.Any();

                        if (!alreadyImported)
                        {
                            // Lookup the previous schedule and get the details to match the accounts and authorized personAliasId
                            var financialScheduleTransactionDetailService = new FinancialScheduledTransactionDetailService(newRockContext);
                            var financialPersonSavedAccountService = new FinancialPersonSavedAccountService(newRockContext);
                            var fstService = new FinancialScheduledTransactionService(newRockContext);
                            var previousSchedule = fstService.Queryable().Where(x => x.FinancialGatewayId == previousGatewayId && x.GatewayScheduleId == schedule.PreviousGatewayScheduleId).FirstOrDefault();
                            // Check for saved account with previous gateway.
                            var previousSavedAccount = financialPersonSavedAccountService.Queryable().Where(x => x.FinancialGatewayId == previousGatewayId && x.GatewayPersonIdentifier == schedule.PreviousGatewayPersonIdentifier).FirstOrDefault();
                            // Check to make sure the payment method isn't already added with the new gateway
                            var newSavedAccount = financialPersonSavedAccountService.Queryable().Where(x => x.FinancialGatewayId == myWellFinancialGatewayId && x.GatewayPersonIdentifier == schedule.GatewayPersonIdentifier).FirstOrDefault();

                            var month = schedule.ExpirationDate.IsNotNullOrWhiteSpace() ? schedule.ExpirationDate.Split('/')[0].AsIntegerOrNull() : null;
                            var year = schedule.ExpirationDate.IsNotNullOrWhiteSpace() ? schedule.ExpirationDate.Split('/')[1].AsIntegerOrNull() : null;

                            if (previousSchedule == null)
                            {
                                throw new Exception($"My Well Import Error: Could not find previous Schedule {schedule.PreviousGatewayScheduleId} within financial gateway Id: {previousGatewayId}. Importing My Well Schedule {schedule.GatewayScheduleId} failed!");
                            }

                            if (previousSchedule.IsActive == false)
                            {
                                throw new Exception(string.Format("The previous schedule {0} is currently INACTIVE. The corresponding schedule {1} was not created. Please cancel the imported schedule on My Well Portal.<br/>", previousSchedule.GatewayScheduleId, schedule.GatewayScheduleId));
                            }

                            if (previousSchedule.TotalAmount != schedule.Amount || previousSchedule.TransactionFrequencyValueId != schedule.TransactionFrequencyValueId || previousSchedule.NextPaymentDate != schedule.StartDate)
                            {
                                throw new Exception(string.Format("The previous schedule {0} fields do not match the new schedule. Ex: amount, frequency or nextPaymentDate. The corresponding schedule {1} was not created. Please correct the My Well schedule and re-import with correct parameters.<br/>", previousSchedule.GatewayScheduleId, schedule.GatewayScheduleId));
                            }

                            var financialPaymentDetail = new FinancialPaymentDetail
                            {
                                AccountNumberMasked = schedule.AccountNumberMasked,
                                CurrencyTypeValueId = previousSchedule.FinancialPaymentDetail.CurrencyTypeValueId,
                                CreditCardTypeValueId = previousSchedule.FinancialPaymentDetail.CreditCardTypeValueId,
                                GatewayPersonIdentifier = schedule.GatewayPersonIdentifier,
                                ExpirationMonth = previousSchedule.FinancialPaymentDetail.ExpirationMonth,
                                ExpirationYear = previousSchedule.FinancialPaymentDetail.ExpirationYear,
                                BillingLocationId = previousSchedule.FinancialPaymentDetail.BillingLocationId,
                                NameOnCard = previousSchedule.FinancialPaymentDetail.NameOnCard,
                                CreatedByPersonAliasId = previousSchedule.FinancialPaymentDetail.CreatedByPersonAliasId,
                                ModifiedByPersonAliasId = previousSchedule.FinancialPaymentDetail.ModifiedByPersonAliasId
                            };

                            // if the saved payment method already exists then we can
                            if (newSavedAccount != null)
                            {
                                financialPaymentDetail.FinancialPersonSavedAccountId = newSavedAccount.Id;
                            }

                            var financialScheduleTransaction = new FinancialScheduledTransaction
                            {
                                TransactionCode = schedule.TransactionCode,
                                FinancialPaymentDetail = financialPaymentDetail,
                                FinancialGatewayId = myWellFinancialGatewayId,
                                AuthorizedPersonAliasId = previousSchedule.AuthorizedPersonAliasId,
                                TransactionFrequencyValueId = schedule.TransactionFrequencyValueId,
                                GatewayScheduleId = schedule.GatewayScheduleId,
                                NextPaymentDate = schedule.StartDate,
                                StartDate = schedule.StartDate,
                                CardReminderDate = previousSchedule.CardReminderDate,
                                LastRemindedDate = previousSchedule.LastRemindedDate,
                                SourceTypeValueId = previousSchedule.SourceTypeValueId,
                                TransactionTypeValueId = previousSchedule.TransactionTypeValueId,
                                Summary = previousSchedule.Summary,
                                CreatedByPersonAliasId = previousSchedule.CreatedByPersonAliasId,
                                ModifiedByPersonAliasId = previousSchedule.ModifiedByPersonAliasId,
                                Status = FinancialScheduledTransactionStatus.Active,
                            };

                            foreach (var scheduleDetail in previousSchedule.ScheduledTransactionDetails)
                            {
                                var financialScheduleTransactionDetail = new FinancialScheduledTransactionDetail();
                                financialScheduleTransactionDetail.AccountId = scheduleDetail.AccountId;
                                financialScheduleTransactionDetail.Amount = scheduleDetail.Amount;
                                financialScheduleTransactionDetail.ScheduledTransaction = financialScheduleTransaction;
                                financialScheduleTransactionDetail.FeeCoverageAmount = scheduleDetail.FeeCoverageAmount;
                                financialScheduleTransactionDetail.EntityId = scheduleDetail.EntityId;
                                financialScheduleTransactionDetail.EntityTypeId = scheduleDetail.EntityTypeId;
                                financialScheduleTransactionDetail.Summary = scheduleDetail.Summary;
                                financialScheduleTransactionDetail.FeeCoverageAmount = scheduleDetail.FeeCoverageAmount;
                                financialScheduleTransactionDetail.CreatedByPersonAliasId = previousSchedule.CreatedByPersonAliasId;
                                financialScheduleTransactionDetail.ModifiedByPersonAliasId = previousSchedule.ModifiedByPersonAliasId;
                                financialScheduleTransactionDetailService.Add(financialScheduleTransactionDetail);
                            }

                            newRockContext.SaveChanges();

                            // If a user had a saved payment method with their previous gateway, we will create a
                            // new saved payment for them for the My Well Gateway.
                            if (previousSavedAccount != null && newSavedAccount == null)
                            {
                                var financialPersonSavedAccount = new FinancialPersonSavedAccount
                                {
                                    ReferenceNumber = schedule.GatewayPersonIdentifier,
                                    Name = previousSavedAccount.Name,
                                    TransactionCode = schedule.GatewayScheduleId,
                                    PersonAliasId = previousSavedAccount.PersonAliasId,
                                    GroupId = previousSavedAccount.GroupId,
                                    FinancialGatewayId = myWellFinancialGatewayId,
                                    GatewayPersonIdentifier = schedule.GatewayPersonIdentifier,
                                    IsDefault = previousSavedAccount.IsDefault,
                                    PreferredForeignCurrencyCodeValueId = previousSavedAccount.PreferredForeignCurrencyCodeValueId,
                                    CreatedByPersonAliasId = previousSavedAccount.CreatedByPersonAliasId,
                                };

                                // rock has a wierd way of storing the payment info of a saved payment method.
                                // It creates a new table entry for it instead of using the payment method of the schedule
                                financialPersonSavedAccount.FinancialPaymentDetail = new FinancialPaymentDetail();
                                financialPersonSavedAccount.FinancialPaymentDetail.AccountNumberMasked = financialPaymentDetail.AccountNumberMasked;
                                financialPersonSavedAccount.FinancialPaymentDetail.CurrencyTypeValueId = financialPaymentDetail.CurrencyTypeValueId;
                                financialPersonSavedAccount.FinancialPaymentDetail.CreditCardTypeValueId = financialPaymentDetail.CreditCardTypeValueId;
                                financialPersonSavedAccount.FinancialPaymentDetail.NameOnCard = financialPaymentDetail.NameOnCard;
                                financialPersonSavedAccount.FinancialPaymentDetail.ExpirationMonth = financialPaymentDetail.ExpirationMonth;
                                financialPersonSavedAccount.FinancialPaymentDetail.ExpirationYear = financialPaymentDetail.ExpirationYear;
                                financialPersonSavedAccount.FinancialPaymentDetail.BillingLocationId = financialPaymentDetail.BillingLocationId;
                                financialPersonSavedAccount.FinancialPaymentDetail.CreatedByPersonAliasId = financialPaymentDetail.CreatedByPersonAliasId;
                                financialPersonSavedAccount.FinancialPaymentDetail.ModifiedByPersonAliasId = financialPaymentDetail.ModifiedByPersonAliasId;

                                financialPersonSavedAccountService.Add(financialPersonSavedAccount);
                                financialPaymentDetail.FinancialPersonSavedAccountId = financialPersonSavedAccount.Id;

                                // If delete payment method attribute is enabled then delete the users previous gateway payment method
                                // check if we can delete
                                var deletePreviousPaymentMethod = GetAttributeValue(AttributeKey.DeletePreviousSavedAccount).AsBooleanOrNull() ?? false;
                                if (deletePreviousPaymentMethod)
                                {
                                    string deleteError;
                                    if (!financialPersonSavedAccountService.CanDelete(previousSavedAccount, out deleteError))
                                    {
                                        errorMessage.Add(string.Format("Saved new payment method for person alias Id {0} for the My Well Gateway, but could not delete the person's previous saved payment method {1} for previous schedule Id {2}.<br/>", previousSavedAccount.PersonAliasId, schedule.PreviousGatewayPersonIdentifier, previousSchedule.GatewayScheduleId));
                                    }
                                    else
                                    {
                                        // creating new context since using the previous one deletes the payment details of the schedule too which we don't want
                                        var savedAccountContext = new RockContext();
                                        var savedAccountService = new FinancialPersonSavedAccountService(savedAccountContext);

                                        var savedAccount = savedAccountService.Get(previousSavedAccount.Id);
                                        savedAccountService.Delete(savedAccount);
                                        savedAccountContext.SaveChanges();
                                    }
                                }
                                newRockContext.SaveChanges();

                            }

                            // if a saved payment method was already added (for a previous my well schedule), then use it for this one
                            if (newSavedAccount != null)
                            {
                                financialPaymentDetail.FinancialPersonSavedAccountId = newSavedAccount.Id;
                                newRockContext.SaveChanges();
                            }

                            //Update our my well table and set schedule as imported
                            var financialSchedule = new FinancialScheduledTransactionService(newRockContext).Queryable().Where(x => x.GatewayScheduleId == schedule.GatewayScheduleId).FirstOrDefault();
                            var myWellScheduleLookUp = new MyWellGatewayScheduleService(newRockContext).Queryable().Where(x => x.Id == schedule.Id).FirstOrDefault(); ;

                            // update the isImported field in my well table
                            if (financialSchedule != null)
                            {
                                myWellScheduleLookUp.ProcessedByPersonAliasId = this.CurrentPersonAliasId;
                                myWellScheduleLookUp.ProcessedDateTime = financialSchedule.CreatedDateTime;
                                myWellScheduleLookUp.IsImported = true;
                                myWellScheduleLookUp.FinancialScheduledTransactionId = financialSchedule.Id;
                                myWellScheduleLookUp.AuthorizedPersonAliasId = financialSchedule.AuthorizedPersonAliasId;
                                newRockContext.SaveChanges();
                            }
                            else
                            {
                                string error = $"My Well Schedule {schedule.GatewayScheduleId} was not found in the database. Import failed!";
                                throw new Exception(error);
                            }

                            successfulImport++;

                            // Cancel the previous schedule 
                            if (previousSchedule.FinancialGateway != null)
                            {
                                previousSchedule.FinancialGateway.LoadAttributes(newRockContext);
                            }

                            string errorMessages = string.Empty;
                            CancelSchedule(fstService, previousSchedule, out errorMessages);

                            if (!errorMessages.IsNotNullOrWhiteSpace())
                            {
                                newRockContext.SaveChanges();
                                successfulStopped++;
                            }
                            else
                            {
                                errorMessage.Add(string.Format("Failed to Stop {0}: {1}", schedule.PreviousGatewayScheduleId, errorMessages));
                            }
                        }
                        else
                        {
                            string error = string.Format("A schedule of {0} already exists! <br/>", schedule.GatewayScheduleId);
                            errorMessage.Add(error);
                            schedule.ProcessedByPersonAliasId = this.CurrentPersonAliasId;
                            schedule.ProcessedDateTime = lookupSchedule.FirstOrDefault().CreatedDateTime;
                            schedule.IsImported = true;
                            schedule.AuthorizedPersonAliasId = lookupSchedule.FirstOrDefault().AuthorizedPersonAliasId;
                            schedule.IsImported = true;
                            schedule.FinancialScheduledTransactionId = lookupSchedule.FirstOrDefault().Id;
                            newRockContext.SaveChanges();
                        }

                    }
                    catch (Exception ex)
                    {
                        string error = string.Format("Schedule {0} failed to import! <br/>", schedule.GatewayScheduleId);
                        errorMessage.Add(error);
                        LogException(ex);
                    }
                }

                _hubContext.Clients.All.done(this.SignalRNotificationKey,
               string.Format("<p>Successfully imported <strong>{0}</strong> of <strong>{1}</strong> schedules.</br>Successfully cancelled <strong>{2}</strong> of <strong>{1}</strong> previous schedules.</p>", successfulImport, schedulesNotImported.Count, successfulStopped));

                // print out the scheduels that were not imported. These schedules are in the exception logs as weel.
                if (errorMessage.Count > 0)
                {
                    var errors = String.Empty;
                    errorMessage.ForEach(x => errors += x);
                    WriteErrorMessage(errors);
                    // logs to rock logger
                    errorMessage.ForEach(e => RockLogger.Log.Error(RockLogDomains.Finance, e));
                }
            }

            rockContext = new RockContext();

            // check if all are imported then mark this imprt as imported and active
            var importQry = new MyWellGatewayScheduleImportService(rockContext).Queryable().Where(x => x.Id == importId);
            var importSchedulesQry = importQry.Select(x => x.Schedules).FirstOrDefault();

            if (importSchedulesQry != null && importSchedulesQry.All(x => x.IsImported))
            {
                importQry.FirstOrDefault().IsActivated = true;
                importQry.FirstOrDefault().Status = ImportStatus.Imported;
                rockContext.SaveChanges();
            }
        }

        /// <summary>
        /// Method to cancel a schedule.
        /// </summary>
        /// <param name="importId">The import identifier.</param>
        public void CancelSchedule(FinancialScheduledTransactionService fstService, FinancialScheduledTransaction schedule, out string errorMessages)
        {
            var cancelRockContext = new RockContext();

            var myWellScheduleLookUp = new MyWellGatewayScheduleService(cancelRockContext).Queryable().Where(x => x.PreviousGatewayScheduleId == schedule.GatewayScheduleId).FirstOrDefault(); ;

            if (fstService.Cancel(schedule, out errorMessages))
            {

                // We will check to make sure the schedule is actually cancelled and then update the my well table
                var gateway = schedule.FinancialGateway.GetGatewayComponent();

                // If the schedule is deleted, then there is an error thrown that schedule does not exist.
                // we will check if there is an error thrown here. If there is, then we assumee the schedule is cancelled already and reset the schedule
                var isActive = gateway.GetScheduledPaymentStatus(schedule, out errorMessages);
                errorMessages = String.Empty;

                if (isActive)
                {
                    errorMessages = string.Format("Failed to cancel schedule {0}. Please manually cancel the schedule.< br /> ", schedule.GatewayScheduleId);
                    return;
                }
                else
                {
                    if (myWellScheduleLookUp != null)
                    {
                        // Update the My Well tables to document that the previous schedule is actually cancelled
                        myWellScheduleLookUp.PreviousScheduleStatus = false;
                    }
                    else
                    {
                        errorMessages = "Failed to lookup schedule";
                        return;
                    }
                }

                cancelRockContext.SaveChanges();
            }
            else
            {
                errorMessages = string.Format("Error cancelling schedule {0}. Please manually cancel the schedule.< br /> ", schedule.GatewayScheduleId);
                return;
            }
        }

        /// <summary>
        /// Shows the detail.
        /// </summary>
        /// <param name="importId">The import identifier.</param>
        public void ShowDetail(int importId)
        {
            btnFilter.Visible = true;
            pnlScheduleDetails.Visible = true;

            hfImportId.Value = importId.ToString();
            hfScheduleId.Value = string.Empty;

            int? specificScheduleId = PageParameter(PageParameterKey.ScheduleId).AsIntegerOrNull();
            if (specificScheduleId.HasValue)
            {
                hfBackNextHistory.Value = specificScheduleId.Value.ToString();
                btnCancel.Visible = true;
                btnNext.Text = "Save";
            }

            NavigateToSchedule(IsPostBack ? Direction.Current : Direction.Next);
        }

        /// <summary>
        ///
        /// </summary>
        private enum Direction
        {
            Prev,
            Next,
            Current
        }


        /// <summary>
        /// Navigates to the next (or previous) schedule to import
        /// </summary>
        private void NavigateToSchedule(Direction direction)
        {
            hfDoFadeIn.Value = "1";
            nbSaveError.Visible = false;
            int? fromScheduleId = hfScheduleId.Value.AsIntegerOrNull();
            int? toScheduleId = null;

            // reset the visible optional account ids everytime they navigate to a new schedule
            _visibleOptionalAccountIds = new List<int>();

            List<int> historyList = hfBackNextHistory.Value.Split(new char[] { ',' }, StringSplitOptions.RemoveEmptyEntries).AsIntegerList().Where(a => a > 0).ToList();
            int position = hfHistoryPosition.Value.AsIntegerOrNull() ?? -1;

            if (direction == Direction.Prev)
            {
                position--;
            }
            else if (direction == Direction.Next)
            {
                position++;
            }
            else if (direction == Direction.Current)
            {
                // If navigate is set to stay on current, stay on the current schedule ( and don't change history position )
                toScheduleId = fromScheduleId;
            }

            if ((toScheduleId == null) && (historyList.Count > position))
            {
                if (position >= 0)
                {
                    toScheduleId = historyList[position];
                }
                else
                {
                    // if we trying to go previous when we are already at the start of the list, wrap around to the last item in the list
                    toScheduleId = historyList.Last();
                    position = historyList.Count - 1;
                }
            }

            hfHistoryPosition.Value = position.ToString();

            int importId = hfImportId.Value.AsInteger();
            var rockContext = new RockContext();

            var myWellGatewayScheduleService = new MyWellGatewayScheduleService(rockContext);
            var myWellGatewayScheduleImportService = new MyWellGatewayScheduleImportService(rockContext);
            var qryScheduleToMatch = myWellGatewayScheduleService.Queryable()
                .Where(a => !a.IsImported);

            var importExists = false;

            if (importId != 0)
            {
                qryScheduleToMatch = qryScheduleToMatch.Where(a => a.ImportId == importId);
                importExists = myWellGatewayScheduleImportService.Queryable().Where(x => x.Id == importId).FirstOrDefault() != null;
            }

            if (importExists)
            {
                // if a specific scheduleId was specified (because we are navigating thru history), load that one. Otherwise, if a import is specified, get the first unmatched schedule in that import
                if (toScheduleId.HasValue)
                {
                    qryScheduleToMatch = myWellGatewayScheduleService
                        .Queryable()
                        .Where(a => a.Id == toScheduleId);
                }

                if (historyList.Any() && !toScheduleId.HasValue)
                {
                    // since we are looking for a schedule we haven't viewed or matched yet, look for the next one in the database that we haven't seen yet
                    qryScheduleToMatch = qryScheduleToMatch.Where(a => !historyList.Contains(a.Id));
                }

                // put them in a predictable order
                qryScheduleToMatch = qryScheduleToMatch.OrderBy(a => a.CreatedDateTime).ThenBy(a => a.Id);

                MyWellGatewaySchedule scheduleToMatch = qryScheduleToMatch.FirstOrDefault();

                if (scheduleToMatch == null)
                {
                    plnComplete.Visible = true;
                    plnContent.Visible = false;
                    lbFinish.Visible = true;
                    pnlScheduleDetails.Visible = false;
                    btnFilter.Visible = false;
                    pMatchSchedule.Visible = false;
                    pActionButtons.Visible = false;
                }

                if (scheduleToMatch != null)
                {
                    plnComplete.Visible = false;
                    plnContent.Visible = true;
                    lbFinish.Visible = false;
                    pnlScheduleDetails.Visible = true;
                    hfScheduleId.Value = scheduleToMatch.Id.ToString();

                    // stored the value in cents to avoid javascript floating point math issues
                    hfOriginalTotalAmount.Value = (scheduleToMatch.Amount * 100).ToString();
                    hfCurrencySymbol.Value = RockCurrencyCodeInfo.GetCurrencySymbol();

                    if (direction != Direction.Current)
                    {
                        ppSelectNew.SetValue(null);
                        pnlPreview.Visible = false;
                    }

                    // update accountboxes
                    foreach (var accountBox in rptAccounts.ControlsOfTypeRecursive<CurrencyBox>())
                    {
                        accountBox.Value = null;
                    }

                    bool existingAmounts = false;

                    if (existingAmounts)
                    {
                        string keyPrefix = GetUserPreferenceKeyPrefix();
                        bool onlyShowSelectedAccounts = this.GetUserPreference(keyPrefix + "only-show-selected-accounts").AsBoolean();
                        UpdateVisibleAccountBoxes(onlyShowSelectedAccounts);
                    }
                    else
                    {
                        UpdateVisibleAccountBoxes();
                    }

                    int currentScheduleId = hfScheduleId.Value.AsInteger();

                    var currentSchedule = myWellGatewayScheduleService.Queryable().Where(x => x.Id == currentScheduleId).FirstOrDefault();
                    var detailsRight = new DescriptionList();
                    var detailsCenter = new DescriptionList();
                    var detailsLeft = new DescriptionList();
                    var scheduleDetails = new StringBuilder();

                    detailsRight.Add("Person", $"{currentSchedule.FirstName} {currentSchedule.LastName}");
                    detailsRight.Add("Email", $"{currentSchedule.Email}");
                    if (currentSchedule.Street1.IsNotNullOrWhiteSpace())
                    {
                        detailsRight.Add("Address", $"{currentSchedule.Street1}<br/>{currentSchedule.City}, {currentSchedule.State} {currentSchedule.PostalCode}");
                    }

                    lDetailsRight.Text = detailsRight.Html;

                    scheduleDetails.Append($"<b>Id: </b>{currentSchedule.GatewayPersonIdentifier}");

                    var mywellPortalUrl = GlobalAttributesCache.Value("MyWellGatewayPortalURL");

                    detailsCenter.Add("Previous Gateway Id", currentSchedule.PreviousGatewayScheduleId);
                    detailsCenter.Add("Schedule Id", $"<a target='_blank' href='{mywellPortalUrl}/schedules/{currentSchedule.GatewayScheduleId}'>{currentSchedule.GatewayScheduleId}</a>");
                    detailsCenter.Add("Frequency", currentSchedule.TransactionFrequencyValue);
                    detailsCenter.Add("Start Date", currentSchedule.StartDate.ToShortDateString());

                    LDetatilsCenter.Text = detailsCenter.Html;

                    if (currentSchedule.AccountNumberMasked.IsNotNullOrWhiteSpace())
                    {
                        if (currentSchedule.CurrencyTypeValueId == DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.CURRENCY_TYPE_ACH.AsGuid()).Id)
                        {
                            detailsLeft.Add("Payment Method", $"Type: {currentSchedule.CurrencyTypeValue} <br/>Account Number: {currentSchedule.AccountNumberMasked}");
                        }
                        else
                        {
                            detailsLeft.Add("Payment Method", $"Type: {currentSchedule.CurrencyTypeValue} - {currentSchedule.CreditCardTypeValue} <br/>Account Number: {currentSchedule.AccountNumberMasked} <br/>Expires: {currentSchedule.ExpirationDate}");
                        }
                    }
                    LDetatilsLeft.Text = detailsLeft.Html;

                    // Lookup the schedule person in rock and try to match them to a rock person
                    // If we find someone, populate the person in the Assing Person dropdown
                    // Match the person by first, last name and their email. If email is not
                    // provided we will not match the person.
                    if (currentSchedule.Email.IsNotNullOrWhiteSpace())
                    {
                        var personQuery = new PersonService.PersonMatchQuery(currentSchedule.FirstName, currentSchedule.LastName, currentSchedule.Email, "");
                        var matchingPerson = new PersonService(rockContext).FindPerson(personQuery, false, false, true);
                        if (matchingPerson != null)
                        {
                            var matchedPersonAliasId = new PersonAliasService(rockContext).GetPrimaryAliasId(matchingPerson.Id).Value;
                            ppSelectNew.SetValue(matchingPerson);
                            LoadPersonPreview(matchingPerson.Id);
                        }
                    }

                    if (_focusControl == null)
                    {
                        _focusControl = rptAccounts.ControlsOfTypeRecursive<Rock.Web.UI.Controls.CurrencyBox>().Where(a => a.Visible).FirstOrDefault();
                    }

                }
                else
                {
                    hfScheduleId.Value = string.Empty;
                }

                // display how many unmatched schedules are remaining
                var qryScheduleCount = myWellGatewayScheduleService.Queryable();
                if (importId != 0)
                {
                    qryScheduleCount = qryScheduleCount.Where(a => a.ImportId == importId);
                }

                // get count of schedules that have been matched (not including the one we are currently editing)
                int matchedCount = qryScheduleCount.Count(a => a.IsImported && a.Id != importId);
                int percentComplete;

                int totalImportItemCount = qryScheduleCount.Count();
                if (totalImportItemCount != 0)
                {
                    percentComplete = (int)Math.Round((double)(100 * matchedCount) / totalImportItemCount);
                }
                else
                {
                    percentComplete = 100;
                }

                var totalSchedules = qryScheduleCount.Select(a => a.Id).Count();
                var totalMatchedSchedules = qryScheduleCount.Where(a => a.IsImported).Count();
                var notMatched = totalSchedules - totalMatchedSchedules;
                var totalAmountSchedules = qryScheduleCount.Select(a => a.Amount).Sum();
                var totalMatchedAmountQry = qryScheduleCount.Where(a => a.IsImported).Select(a => a.Amount);
                decimal notMatchedAmount;
                decimal totalMatchedAmount;

                if (totalMatchedAmountQry.Count() > 0)
                {
                    totalMatchedAmount = totalMatchedAmountQry.Sum();
                    notMatchedAmount = totalAmountSchedules - totalMatchedAmount;
                }
                else
                {
                    notMatchedAmount = 0;
                    totalMatchedAmount = 0;
                }

                var percentAmountComplete = (int)Math.Round((double)(100 * Decimal.ToDouble(totalMatchedAmount)) / Decimal.ToDouble(totalAmountSchedules));
                string progressBarText = String.Empty;

                if (percentComplete != 0)
                {
                    progressBarText = $"{percentComplete}%";
                }

                lProgressBar.Text = string.Format(
                        @"
                        <div class='flex-row w-100 mr-3' >
                        <div class='d-flex w-100 mb-1 mt-3' style='font-size: 18px;'>
                            <div class='flex-eq ml-1'>
                             <p class='mb-0'><b style='font-weight: 700' class='text-blue-500'>{0}</b> of <b style='font-weight: 700'>{1}</b> schedules imported</p>
                            </div>
                            <div class='flex-eq mr-1' style='text-align:right'>
                             <p class='mb-0'><b style='font-weight: 700' class='text-green-500'>{3}</b> of <b style='font-weight: 700'>{4}</b> imported</p>
                            </div>
					    </div>
                        <div class='progress w-100 bg-gray-300'>
                            <div class='progress-bar progress-bar-info' role='progressbar' aria-valuenow='{2}' aria-valuemin='0' aria-valuemax='100' style='width: {5}%;'>
                                <b>{2}</b>
                            </div>
                        </div>
                    </div>
                        ", totalMatchedSchedules, totalSchedules, progressBarText, totalMatchedAmount.FormatAsCurrency(), totalAmountSchedules.FormatAsCurrency(), percentComplete);

                hfBackNextHistory.Value = historyList.AsDelimited(",");
            }
            else
            {
                nbImportNotFound.Visible = true;
                pnlView.Visible = false;
            }

        }

        private void UpdateVisibleAccountBoxes(bool onlyShowSelectedAccounts = false)
        {
            List<int> _sortedAccountIds = _visibleDisplayedAccountIds.ToList();
            _sortedAccountIds.AddRange(_visibleOptionalAccountIds);

            List<int> _visibleAccountBoxes = new List<int>();

            foreach (var accountBox in rptAccounts.ControlsOfTypeRecursive<CurrencyBox>())
            {
                int accountBoxAccountId = accountBox.Attributes["data-account-id"].AsInteger();
                accountBox.Visible = !onlyShowSelectedAccounts && (_visibleDisplayedAccountIds.Contains(accountBoxAccountId) || _visibleOptionalAccountIds.Contains(accountBoxAccountId));

                if (!accountBox.Visible && (accountBox.Value ?? 0.0M) != 0)
                {
                    // if there is a non-zero amount, show the edit box regardless of the account filter settings
                    accountBox.Visible = true;
                }

                if (accountBox.Visible)
                {
                    _visibleAccountBoxes.Add(accountBoxAccountId);
                }

                accountBox.Attributes["data-sort-order"] = _sortedAccountIds.IndexOf(accountBoxAccountId).ToString();
            }
        }

        #endregion

        #region Events

        protected void ReactivateSchedules_Click(object sender, EventArgs e)
        {
            var rockContext = new RockContext();
            var financialPersonSavedAccountService = new FinancialPersonSavedAccountService(rockContext);

            var previousSavedAccount = financialPersonSavedAccountService.Get(2042);

            financialPersonSavedAccountService.Delete(previousSavedAccount);
            rockContext.SaveChanges();
            /*using (var rockContext = new RockContext())
            {
                var financialScheduledTransactionService = new FinancialScheduledTransactionService(rockContext);
                var financialScheduledTransaction = financialScheduledTransactionService.Queryable()
                    .Include(a => a.AuthorizedPersonAlias.Person)
                    .Include(a => a.FinancialGateway).Where(x => x.FinancialGatewayId == 3019).ToList();

                if (financialScheduledTransaction == null)
                {
                    return;
                }

                foreach (var schedule in financialScheduledTransaction)
                {
                    if (schedule.FinancialGateway != null)
                    {
                        schedule.FinancialGateway.LoadAttributes(rockContext);
                    }

                    string errorMessage = string.Empty;
                    if (financialScheduledTransactionService.Reactivate(schedule, out errorMessage))
                    {
                        financialScheduledTransactionService.GetStatus(schedule, out errorMessage);
                        rockContext.SaveChanges();
                    }
                }

            }*/
        }

        /// <summary>
        /// Handles the SaveClick event of the mdAccountsPersonalFilter control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void mdAccountsPersonalFilter_SaveClick(object sender, EventArgs e)
        {
            string keyPrefix = GetUserPreferenceKeyPrefix();

            var selectedAccountIdList = apDisplayedPersonalAccounts.SelectedValuesAsInt().ToList();
            var selectedAccountGuidList = new FinancialAccountService(new RockContext()).GetByIds(selectedAccountIdList).Select(a => a.Guid).ToList();
            this.SetUserPreference(keyPrefix + "account-list", selectedAccountGuidList.AsDelimited(","));

            mdAccountsPersonalFilter.Hide();

            // load the dropdowns again since account filter may have changed
            LoadDropDowns();

            // load the current schedule again to make sure UI shows the accounts based on the updated filter settings
            NavigateToSchedule(Direction.Current);
        }

        /// <summary>
        /// Handles the Click event of the btnFilter control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void btnFilter_Click(object sender, EventArgs e)
        {
            string keyPrefix = GetUserPreferenceKeyPrefix();

            var personalAccountGuidList = (this.GetUserPreference(keyPrefix + "account-list") ?? string.Empty).SplitDelimitedValues().Select(a => a.AsGuid()).ToList();
            var personalAccountList = new FinancialAccountService(new RockContext())
                .GetByGuids(personalAccountGuidList)
                .Where(a => a.IsActive)
                .ToList();
            apDisplayedPersonalAccounts.SetValues(personalAccountList);

            mdAccountsPersonalFilter.Show();
        }


        /// <summary>
        /// Handles the Click event of the btnNext control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void btnNext_Click(object sender, EventArgs e)
        {
            var rockContext = new RockContext();

            int scheduleId = hfScheduleId.Value.AsInteger();

            if (ppSelectNew.PersonId.HasValue)
            {
                // set the AuthorizedPersonId to the person selected in the drop down
                int authorizedPersonId = ppSelectNew.PersonId.Value;
                int authorizedPersonAliasId = new PersonAliasService(rockContext).GetPrimaryAliasId(authorizedPersonId).Value;

                // Create the schedule in Rock
                MyWellGatewayScheduleService mywellGatewayScheudleService = new MyWellGatewayScheduleService(rockContext);
                int? importId = hfImportId.Value.AsIntegerOrNull();
                var scheduleImport = new MyWellGatewayScheduleImportService(rockContext).Queryable().Where(x => x.Id == importId).FirstOrDefault();
                var schedule = mywellGatewayScheudleService.Queryable().Where(x => x.Id == scheduleId).FirstOrDefault();

                var financialScheduleTransactionDetailService = new FinancialScheduledTransactionDetailService(rockContext);
                var month = schedule.ExpirationDate.IsNotNullOrWhiteSpace() ? schedule.ExpirationDate.Split('/')[0].AsIntegerOrNull() : null;
                var year = schedule.ExpirationDate.IsNotNullOrWhiteSpace() ? schedule.ExpirationDate.Split('/')[1].AsIntegerOrNull() : null;

                // var gatewayId = Rock.SystemGuid.DefinedValue.Financial;
                // First make sure a GatewayScheduleId does not already exist with the current schedule
                var financialScheduleTransactionService = new FinancialScheduledTransactionService(rockContext);

                var financialSchedule = financialScheduleTransactionService.Queryable().Where(x => x.GatewayScheduleId == schedule.GatewayScheduleId).FirstOrDefault();

                if (financialSchedule == null)
                {
                    try
                    {
                        var financialPaymentDetail = new FinancialPaymentDetail
                        {
                            AccountNumberMasked = schedule.AccountNumberMasked,
                            CurrencyTypeValueId = schedule.CurrencyTypeValueId,
                            CreditCardTypeValueId = schedule.CreditCardTypeValueId,
                            GatewayPersonIdentifier = schedule.GatewayPersonIdentifier,
                            ExpirationMonth = month,
                            ExpirationYear = year,
                        };

                        var financialScheduleTransaction = new FinancialScheduledTransaction
                        {
                            TransactionCode = schedule.TransactionCode,
                            FinancialPaymentDetail = financialPaymentDetail,
                            FinancialGatewayId = scheduleImport.MigratingToFinancialGatewayId,
                            AuthorizedPersonAliasId = authorizedPersonAliasId,
                            TransactionFrequencyValueId = schedule.TransactionFrequencyValueId,
                            GatewayScheduleId = schedule.GatewayScheduleId,
                            NextPaymentDate = schedule.StartDate,
                            StartDate = schedule.StartDate,
                            IsActive = false,
                            SourceTypeValueId = 10,
                            TransactionTypeValueId = 53,
                            Summary = "",
                            Status = FinancialScheduledTransactionStatus.Active,
                        };

                        foreach (var accountBox in rptAccounts.ControlsOfTypeRecursive<CurrencyBox>())
                        {
                            var amount = accountBox.Value;

                            if (amount.HasValue && amount.Value >= 0)
                            {
                                var financialScheduleTransactionDetail = new FinancialScheduledTransactionDetail();
                                financialScheduleTransactionDetail.AccountId = accountBox.Attributes["data-account-id"].AsInteger();
                                financialScheduleTransactionDetail.Amount = amount.Value;
                                financialScheduleTransactionDetail.ScheduledTransaction = financialScheduleTransaction;
                                financialScheduleTransactionDetailService.Add(financialScheduleTransactionDetail);
                            }
                        }

                        rockContext.SaveChanges();

                        // get the imported schedule
                        financialSchedule = financialScheduleTransactionService.Queryable().Where(x => x.GatewayScheduleId == schedule.GatewayScheduleId).FirstOrDefault();
                    }
                    catch (Exception ex)
                    {
                        nbSaveError.Text = "Error importing schedule." + ex;
                        nbSaveError.Visible = true;
                        LogException(ex);
                    }
                }


                // update fields in my well table
                if (financialSchedule != null)
                {
                    schedule.AuthorizedPersonAliasId = authorizedPersonAliasId;
                    schedule.ProcessedByPersonAliasId = this.CurrentPersonAliasId;
                    schedule.ProcessedDateTime = financialSchedule.CreatedDateTime;
                    schedule.FinancialScheduledTransactionId = financialSchedule.Id;
                    schedule.IsImported = true;
                    rockContext.SaveChanges();
                }

                NavigateToSchedule(Direction.Next);
            }
            else
            {
                nbSaveError.Text = "Please assign a person to this schedule.";
                nbSaveError.Visible = true;
            }
        }

        /// <summary>
        /// Handles the Click event of the btnCancel control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void btnCancel_Click(object sender, EventArgs e)
        {
            var qryParams = new Dictionary<string, string>();
            int? importId = hfImportId.Value.AsIntegerOrNull();
            if (importId.HasValue)
            {
                qryParams.Add(PageParameterKey.ImportId, importId.Value.ToString());
            }

            NavigateToLinkedPage(AttributeKey.DetailPage, qryParams);
        }


        /// <summary>
        /// Handles the SelectPerson event of the ppSelectNew control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void ppSelectNew_SelectPerson(object sender, EventArgs e)
        {
            if (ppSelectNew.PersonId.HasValue)
            {
                LoadPersonPreview(ppSelectNew.PersonId.Value);
                _focusControl = rptAccounts.ControlsOfTypeRecursive<Rock.Web.UI.Controls.CurrencyBox>().Where(a => a.Visible).FirstOrDefault();

                nbSaveError.Text = string.Empty;
                nbSaveError.Visible = false;
            }
            else
            {
                pnlPreview.Visible = false;
            }
        }

        /// <summary>
        /// Handles the Click event of the btnDone control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void btnImportFromPreviousGateway_Click(object sender, EventArgs e)
        {
            btnImportFromPreviousGateway.Visible = false;
            pnlProgress.Visible = true;
            pnlError.Visible = true;
            var importId = PageParameter(PageParameterKey.ImportId).AsInteger();

            // generate url to link back to import detail
            var qryParams = new Dictionary<string, string>();
            qryParams.Add(PageParameterKey.ImportId, importId.ToString());
            var url = LinkedPageUrl(AttributeKey.DetailPage, qryParams);
            lViewImport.Text = string.Format("<a href='{0}' class='btn btn-success'>View Import</a>", url);

            // Start the task in the background to import all schedules and cancel schedules with previous gateway
            var scheduleImport = new MyWellGatewayScheduleImportService(new RockContext()).Queryable().Where(x => x.Id == importId).FirstOrDefault();

            if ((scheduleImport.IsPartial.HasValue && scheduleImport.IsPartial.Value) || scheduleImport.MigratingFromFinancialGateway == null )
            {
                var import = new Task(() => { ImportPartialData(importId, url); });
                import.Start();
            }
            else
            {
                var import = new Task(() => { ImportData(importId, url); });
                import.Start();
            }

        }


        /// <summary>
        /// Handles the Click event of the btnCancelSchedules_Click control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void btnCancelSchedules_Click(object sender, EventArgs e)
        {
            // incase this is visible disable the button
            btnImportFromPreviousGateway.Visible = false;
            btnCancelSchedules.Visible = false;
            lFailedCancellationDescription.Visible = false;
            lImportDescription.Visible = false;
            lMigratingToGateway.Visible = false;
            lPreviousGateway.Visible = false;
            ltCompleteTitle.Text = "<h4>Cancelling Schedules Complete</h4>";
            ltProgressTitle.Text = "<h4>Cancelling Schedules</h4>";
            pnlProgress.Visible = true;
            pnlError.Visible = true;
            var importId = PageParameter(PageParameterKey.ImportId).AsInteger();

            // generate url to link back to import detail
            var qryParams = new Dictionary<string, string>();
            qryParams.Add(PageParameterKey.ImportId, importId.ToString());
            var url = LinkedPageUrl(AttributeKey.DetailPage, qryParams);
            lViewImport.Text = string.Format("<a href='{0}' class='btn btn-success'>View Import</a>", url);

            // Start the task in the background to import all schedules and cancel schedules with previous gateway
            var cancel = new Task(() =>
            {
                var rockContext = new RockContext();
                var failedCancellationScheduleList = new MyWellGatewayScheduleService(rockContext).Queryable().Where(x => x.ImportId == importId && x.PreviousScheduleStatus == true && x.IsImported == true).ToList();
                var financialGateway = new MyWellGatewayScheduleImportService(rockContext).Queryable().Where(x => x.Id == importId).Select(x => x.MigratingFromFinancialGatewayId).FirstOrDefault();
                List<string> errorMessage = new List<string>();
                var successfulStopped = 0;
                var itemCount = 1;
                if (failedCancellationScheduleList.Count != 0 && financialGateway.HasValue)
                {
                    foreach (var schedule in failedCancellationScheduleList)
                    {
                        WriteProgressMessage(string.Format("Cancelling schedule {0} of {1}", itemCount, failedCancellationScheduleList.Count));

                        string errorMessages = string.Empty;
                        var fstService = new FinancialScheduledTransactionService(rockContext);
                        var financialSchedule = fstService.Queryable().Where(x => x.GatewayScheduleId == schedule.PreviousGatewayScheduleId && x.FinancialGatewayId == financialGateway).FirstOrDefault();

                        CancelSchedule(fstService, financialSchedule, out errorMessages);

                        if (!errorMessages.IsNotNullOrWhiteSpace())
                        {
                            successfulStopped++;
                        }
                        else
                        {
                            errorMessage.Add(errorMessages);
                        }
                        itemCount++;
                    }

                    _hubContext.Clients.All.done(this.SignalRNotificationKey,
                        string.Format("<p>Successfully cancelled <strong>{1}</strong> of <strong>{0}</strong> previous schedules.</p>", failedCancellationScheduleList.Count, successfulStopped));

                    // print out the scheduels that were not imported. These schedules are in the exception logs as weel.
                    if (errorMessage.Count > 0)
                    {
                        var errors = String.Empty;
                        errorMessage.ForEach(x => errors += x);
                        WriteErrorMessage(errors);
                        // logs to rock logger
                        errorMessage.ForEach(ex => RockLogger.Log.Error(RockLogDomains.Finance, ex));
                    }
                }
            });

            cancel.Start();
        }


        /// <summary>
        /// Handles the Click event of the btnDone control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void lbFinish_Click(object sender, EventArgs e)
        {
            int? importId = hfImportId.Value.AsIntegerOrNull();
            if (importId.HasValue)
            {
                using (var rockContext = new RockContext())
                {
                    var import = new MyWellGatewayScheduleImportService(rockContext).Get(importId.Value);
                    if (import != null && import.Schedules.All(x => x.IsImported) && import.Status != ImportStatus.Imported)
                    {
                        import.Status = ImportStatus.Imported;
                        rockContext.SaveChanges();
                    }
                }

                NavigateToLinkedPage(AttributeKey.DetailPage, new Dictionary<string, string> { { PageParameterKey.ImportId, importId.Value.ToString() } });
            }
        }

        /// <summary>
        /// Loads the person preview.
        /// </summary>
        /// <param name="personId">The person identifier.</param>
        private void LoadPersonPreview(int? personId)
        {
            string previewHtmlDetails = string.Empty;
            var rockContext = new RockContext();
            var person = new PersonService(rockContext).Get(personId ?? 0);
            pnlPreview.Visible = person != null;
            if (person != null)
            {
                // force the link to open a new scrollable,resizable browser window (and make it work in FF, Chrome and IE) http://stackoverflow.com/a/2315916/1755417
                lPersonName.Text = string.Format("<dt>Matched Person</dt><dd><a href onclick=\"javascript: window.open('/person/{0}', '_blank', 'scrollbars=1,resizable=1,toolbar=1'); return false;\">{1}</a></dd>", person.Id, person.FullName);

                if (CampusCache.All(false).Count > 1)
                {
                    var campus = person.GetCampus();
                    lCampus.Text = campus != null ? string.Format("<dt>Campus</dt><dd>{0}</dd>", campus.Name) : string.Empty;
                }

                var previousDefinedValue = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.GROUP_LOCATION_TYPE_PREVIOUS);
                var addresses = person.GetFamilies().SelectMany(a => a.GroupLocations).OrderBy(l => l.GroupLocationTypeValue.Order).ToList();
                if (addresses.Where(a => a.GroupLocationTypeValueId == previousDefinedValue.Id).Count() > 1)
                {
                    var primaryAddresses = addresses.Where(a => a.GroupLocationTypeValueId != previousDefinedValue.Id).ToList();
                    var previousAddress = addresses.Where(a => a.GroupLocationTypeValueId == previousDefinedValue.Id).ToList();
                    primaryAddresses.Add(previousAddress.First());

                    rptrAddresses.DataSource = primaryAddresses;
                    rptrAddresses.DataBind();
                    rptPrevAddresses.DataSource = previousAddress.Skip(1);
                    rptPrevAddresses.DataBind();
                    btnMoreAddress.Visible = true;
                }
                else
                {
                    rptrAddresses.DataSource = addresses;
                    rptrAddresses.DataBind();
                    btnMoreAddress.Visible = false;
                }
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

        #region Control Helpers

        /// <summary>
        /// Gets the address location.
        /// </summary>
        /// <param name="rockContext">The rock context.</param>
        /// <param name="addressControl">The address control.</param>
        /// <returns></returns>
        private Location GetAddressLocation(RockContext rockContext, AddressControl addressControl)
        {
            var locationService = new LocationService(rockContext);
            return locationService.Get(
                addressControl.Street1,
                addressControl.Street2,
                addressControl.City,
                addressControl.State,
                addressControl.PostalCode,
                addressControl.Country);
        }

        #endregion Control Helpers
    }

}