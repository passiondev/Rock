using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Data.Entity;
using System.Linq;
using System.Text;
using System.Web.UI;
using System.Web.UI.WebControls;
using Rock;
using Rock.Attribute;
using Rock.Constants;
using Rock.Data;
using Rock.Model;
using Rock.Web;
using Rock.Web.Cache;
using org.mywell.MyWellGateway.Model;

namespace RockWeb.Plugins.org_mywell.Gateway
{
    [DisplayName("My Well Gateway Imported Schedule Detail")]
    [Category("My Well > Gateway")]
    [Description("My Well Gateway Imported Schedule Details.")]

    [LinkedPage("Import Detail Page", "Page used to view import.", true, "", "", 0)]
    [LinkedPage("Scheduled Transaction Detail Page", "Page used to view scheduled transaction detail.", true, "", "", 1)]
    [TextField(
        "Platform Admin URL",
        Description = "The My Well Platform Admin URL.",
        IsRequired = false,
        Key = AttributeKey.PlatformAdminUrl)]
    public partial class ScheduleDetail : Rock.Web.UI.RockBlock
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
            public const string PlatformAdminUrl = "PlatformAdminUrl";
        }

        #endregion Attribute Keys

        #region Control Methods

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Init" /> event.
        /// </summary>
        /// <param name="e">An <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnInit(EventArgs e)
        {
            base.OnInit(e);

            var qryParam = new Dictionary<string, string>();
            qryParam.Add("ScheduleId", "PLACEHOLDER");

        }

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Load" /> event.
        /// </summary>
        /// <param name="e">The <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnLoad(EventArgs e)
        {
            if (!Page.IsPostBack)
            {
                ShowDetail(PageParameter("ScheduleId").AsInteger(), PageParameter("ImportId").AsInteger());
            }
        }

        #endregion Control Methods

        #region Methods

        /// <summary>
        /// Navigates to the schedule in the list.
        /// </summary>
        private void ShowNavigationButton(int scheduleId, int importId)
        {
            lbBack.Visible = true;
            lbNext.Visible = true;
            var rockContext = new RockContext();
            var myWellScheduleService = new MyWellGatewayScheduleService(rockContext);
            var scheduleToMatch = myWellScheduleService.Queryable()
                .Where(a => a.ImportId == importId)
                .Select(a => a.Id)
                .ToList();

            var nextSchedule = scheduleToMatch.Where(a => a > scheduleId).Take(1).FirstOrDefault();
            var backSchedule = scheduleToMatch.Where(a => a < scheduleId).LastOrDefault();

            if (nextSchedule != default(int))
            {
                var qryParam = new Dictionary<string, string>();
                qryParam.Add("ImportId", hfImportId.Value);
                qryParam.Add("ScheduleId", nextSchedule.ToStringSafe());
                lbNext.NavigateUrl = new PageReference(CurrentPageReference.PageId, 0, qryParam).BuildUrl();
            }
            else
            {
                lbNext.AddCssClass("disabled");
            }

            if (backSchedule != default(int))
            {
                var qryParam = new Dictionary<string, string>();
                qryParam.Add("ImportId", hfImportId.Value);
                qryParam.Add("ScheduleId", backSchedule.ToStringSafe());
                lbBack.NavigateUrl = new PageReference(CurrentPageReference.PageId, 0, qryParam).BuildUrl();
            }
            else
            {
                lbBack.AddCssClass("disabled");
            }
        }

        /// <summary>
        /// Gets the schedule.
        /// </summary>
        /// <param name="scheduleId">The schedule identifier.</param>
        /// <param name="rockContext">The rock context.</param>
        /// <returns></returns>
        private MyWellGatewaySchedule GetSchedule(int scheduleId, RockContext rockContext = null)
        {
            rockContext = rockContext ?? new RockContext();
            var txn = new MyWellGatewayScheduleService(rockContext)
                .Queryable()
                .Where(t => t.Id == scheduleId)
                .FirstOrDefault();
            return txn;
        }

        /// <summary>
        /// Shows the detail.
        /// </summary>
        /// <param name="scheduleId">The schedule identifier.</param>
        /// <param name="importId">The import identifier.</param>
        public void ShowDetail(int scheduleId, int importId)
        {
            var rockContext = new RockContext();

            MyWellGatewaySchedule schedule = GetSchedule(scheduleId, rockContext); ;
            MyWellGatewayScheduleImport import = new MyWellGatewayScheduleImportService(rockContext).Get(importId);

            hfScheduleId.Value = scheduleId.ToString();
            hfImportId.Value = importId.ToString();
            pnlEditDetails.Visible = false;
            ShowNavigationButton(scheduleId, importId);
            ShowReadOnlyDetails(schedule);
        }

        /// <summary>
        /// Shows the read only schedule details.
        /// </summary>
        /// <param name="schedule">The schedule.</param>
        private void ShowReadOnlyDetails(MyWellGatewaySchedule schedule)
        {
            if (schedule != null)
            {
                hfScheduleId.Value = schedule.Id.ToString();
                SetHeadingInfo(schedule);

                var rockContext = new RockContext();
                var financialScheduledTransaction = new FinancialScheduledTransactionService(rockContext);
                var route = LinkedPageRoute("ScheduledTransactionDetailPage");
                string platformGatewayUrl = GetAttributeValue(AttributeKey.PlatformAdminUrl);

                var financialSchedule = financialScheduledTransaction.Queryable().Where(x => x.GatewayScheduleId == schedule.GatewayScheduleId).FirstOrDefault();
                string rockUrlRoot = ResolveRockUrl("/");
                var detailsLeft = new DescriptionList();
                var personToDisplay = $"{schedule.FirstName} {schedule.LastName}";
                var scheduleIdToDisplay = String.Empty;
                var scheduleGatewayIdToDisplay = schedule.GatewayScheduleId;

                if (financialSchedule != null)
                {
                    var qryParam = new Dictionary<string, string>();
                    qryParam.Add("ScheduledTransactionId", financialSchedule.Id.ToString());
                    personToDisplay = $"<a href='/person/{financialSchedule.AuthorizedPersonAlias.PersonId}' target='_blank'> {schedule.FirstName} {schedule.LastName}</a>";
                    scheduleGatewayIdToDisplay = $"<a href='{route}/{financialSchedule.Id}' target='_blank'>{schedule.GatewayScheduleId}</a>";
                }

                detailsLeft.Add("Person", personToDisplay);
                detailsLeft.Add("Email", schedule.Email);

                if (schedule.Street1.IsNotNullOrWhiteSpace())
                {
                    detailsLeft.Add("Address", $"{schedule.Street1} <br/> {schedule.City}, {schedule.State} {schedule.PostalCode}");
                }

                detailsLeft.Add("Schedule Id", scheduleGatewayIdToDisplay);
                detailsLeft.Add("Gateway Person Id", schedule.GatewayPersonIdentifier);

                var modified = new StringBuilder();

                if (schedule.CreatedByPersonAlias != null && schedule.CreatedByPersonAlias.Person != null && schedule.CreatedDateTime.HasValue)
                {
                    modified.AppendFormat("Created by {0} on {1} at {2}<br/>", schedule.CreatedByPersonAlias.Person.GetAnchorTag(rockUrlRoot),
                    schedule.CreatedDateTime.Value.ToShortDateString(), schedule.CreatedDateTime.Value.ToShortTimeString());
                }

                if (financialSchedule != null && schedule.ProcessedByPersonAliasId.HasValue)
                {
                    var processedByPerson = new PersonAliasService(rockContext).GetPerson(schedule.ProcessedByPersonAliasId.Value);
                    modified.AppendFormat("Imported by {0} on {1} at {2}<br/>", processedByPerson.GetAnchorTag(rockUrlRoot),
                    financialSchedule.CreatedDateTime.Value.ToShortDateString(),
                    financialSchedule.CreatedDateTime.Value.ToShortTimeString());
                }

                detailsLeft.Add("Updates", modified.ToString());
                lDetailsLeft.Text = detailsLeft.Html;

                var detailsRight = new DescriptionList();
                detailsRight.Add("Amount", schedule.Amount.FormatAsCurrency());
                detailsRight.Add("Frequency", schedule.TransactionFrequencyValue);
                detailsRight.Add("Start Date", schedule.StartDate.ToShortDateString());

                if (schedule.AccountNumberMasked != null && schedule.CurrencyTypeValue != null)
                {
                    var paymentMethodDetails = new DescriptionList();

                    var currencyType = schedule.CurrencyTypeValue;
                    if (currencyType.Guid.Equals(Rock.SystemGuid.DefinedValue.CURRENCY_TYPE_CREDIT_CARD.AsGuid()))
                    {
                        // Credit Card
                        paymentMethodDetails.Add(string.Empty, currencyType.Value + (schedule.CreditCardTypeValue != null ? (" - " + schedule.CreditCardTypeValue.Value) : string.Empty));
                        paymentMethodDetails.Add("Name on Card:", $"{schedule.FirstName} {schedule.LastName}");
                        paymentMethodDetails.Add("Account Number:", schedule.AccountNumberMasked);
                        paymentMethodDetails.Add("Expires:", schedule.ExpirationDate);
                    }
                    else
                    {
                        // ACH
                        paymentMethodDetails.Add(string.Empty, currencyType.Value);
                        paymentMethodDetails.Add("Account Number:", schedule.AccountNumberMasked);
                    }
                    detailsRight.Add("Payment Method", paymentMethodDetails.GetFormattedList("{0} {1}").AsDelimited("<br/>"));
                }
                else
                {
                    detailsRight.Add("Payment Method", "None");
                }

                // Add the link for the privousGatewayScheduleId in case previous schedule is from a gateway in rock
                var importedSchedule = new MyWellGatewayScheduleImportService(rockContext).Queryable().FirstOrDefault(x => x.Id == schedule.ImportId && x.MigratingFromFinancialGatewayId.HasValue);
                var previousSchedule = financialScheduledTransaction.Queryable().Where(x => x.GatewayScheduleId == schedule.PreviousGatewayScheduleId).FirstOrDefault();

                if (importedSchedule != null && previousSchedule != null)
                {
                    detailsRight.Add("Previous Gateway Schedule Id", $"<a href='{route}/{previousSchedule.Id}' target='_blank'>{schedule.PreviousGatewayScheduleId}</a>");
                }
                else if (!string.IsNullOrEmpty(schedule.PreviousGatewayScheduleId))
                {
                    detailsRight.Add("Previous Gateway Schedule Id", platformGatewayUrl.IsNotNullOrWhiteSpace() ? $"<a href='{platformGatewayUrl}/admin/schedules/{schedule.PreviousGatewayScheduleId}' target='_blank'>{schedule.PreviousGatewayScheduleId}</a>" : schedule.PreviousGatewayScheduleId);
                }

                if (!string.IsNullOrEmpty(schedule.PreviousGatewayPersonIdentifier))
                {
                    detailsRight.Add("Previous Gateway Person Id", platformGatewayUrl.IsNotNullOrWhiteSpace() ? $"<a href='{platformGatewayUrl}/admin/givers/{schedule.PreviousGatewayPersonIdentifier}/details' target='_blank'>{schedule.PreviousGatewayPersonIdentifier}</a>" :  schedule.PreviousGatewayPersonIdentifier);
                }

                if (!schedule.IsImported)
                {
                    btnUpdate.Visible = true;
                }

                lDetailsRight.Text = detailsRight.Html;
            }
            else
            {
                nbEditModeMessage.Text = EditModeMessage.NotAuthorizedToEdit(FinancialTransaction.FriendlyTypeName);
            }
        }

        /// <summary>
        /// Handles the Click event of the lbEdit control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void lbEdit_Click(object sender, EventArgs e)
        {
            btnUpdate.Visible = false;
            lbSave.Visible = true;
            lbCancel.Visible = true;
            pnlEditDetails.Visible = true;
            ShowEditDetails(PageParameter("ScheduleId").AsInteger(), PageParameter("ImportId").AsInteger());

            var rockContext = new RockContext();

            MyWellGatewaySchedule schedule = GetSchedule(PageParameter("ScheduleId").AsInteger(), rockContext);

            if (schedule.AuthorizedPersonAliasId.HasValue)
            {
                var personAlias = new PersonAliasService(rockContext).Get(schedule.AuthorizedPersonAliasId.Value);

                if (personAlias != null)
                {
                    ppSelectNew.SetValue(personAlias.Person);
                }
            }

            // for now we only support one account import per schedule
            if (schedule.AccountAllocation.Count > 0)
            {
                var mywellAccountAllocation = new MyWellGatewayScheduleAccountAllocationService(rockContext).Queryable().Where(s => s.ScheduleId == schedule.Id).FirstOrDefault();
                if (mywellAccountAllocation != null)
                {
                    apDisplayedPersonalAccounts.SetValue(mywellAccountAllocation.FinancialAccount);
                }
            }

        }

        /// <summary>
        /// Shows the edit details.
        /// </summary>
        /// <param name="batch">The financial batch.</param>
        protected void ShowEditDetails(int scheduleId, int importId)
        {
            var rockContext = new RockContext();

            MyWellGatewaySchedule schedule = GetSchedule(scheduleId, rockContext); ;
            MyWellGatewayScheduleImport import = new MyWellGatewayScheduleImportService(rockContext).Get(importId);

            hfScheduleId.Value = scheduleId.ToString();
            hfImportId.Value = importId.ToString();
            ShowNavigationButton(scheduleId, importId);


            if (schedule != null)
            {
                hfScheduleId.Value = schedule.Id.ToString();
                SetHeadingInfo(schedule);

                var financialScheduledTransaction = new FinancialScheduledTransactionService(rockContext);
                var route = LinkedPageRoute("ScheduledTransactionDetailPage");

                var financialSchedule = financialScheduledTransaction.Queryable().Where(x => x.GatewayScheduleId == schedule.GatewayScheduleId).FirstOrDefault();
                string rockUrlRoot = ResolveRockUrl("/");
                var detailsLeft = new DescriptionList();
                var personToDisplay = $"{schedule.FirstName} {schedule.LastName}";
                var scheduleIdToDisplay = String.Empty;
                var scheduleGatewayIdToDisplay = schedule.GatewayScheduleId;

                if (financialSchedule != null)
                {
                    var qryParam = new Dictionary<string, string>();
                    qryParam.Add("ScheduledTransactionId", financialSchedule.Id.ToString());
                    personToDisplay = $"<a href='/person/{financialSchedule.AuthorizedPersonAlias.PersonId}' target='_blank'> {schedule.FirstName} {schedule.LastName}</a>";
                    scheduleGatewayIdToDisplay = $"<a href='{route}/{financialSchedule.Id}' target='_blank'>{schedule.GatewayScheduleId}</a>";
                }

                detailsLeft.Add("Person", personToDisplay);
                detailsLeft.Add("Email", schedule.Email);

                if (schedule.Street1.IsNotNullOrWhiteSpace())
                {
                    detailsLeft.Add("Address", $"{schedule.Street1} <br/> {schedule.City}, {schedule.State} {schedule.PostalCode}");
                }

                detailsLeft.Add("Schedule Id", scheduleGatewayIdToDisplay);
                detailsLeft.Add("Gateway Person Id", schedule.GatewayPersonIdentifier);

                var modified = new StringBuilder();

                if (schedule.CreatedByPersonAlias != null && schedule.CreatedByPersonAlias.Person != null && schedule.CreatedDateTime.HasValue)
                {
                    modified.AppendFormat("Created by {0} on {1} at {2}<br/>", schedule.CreatedByPersonAlias.Person.GetAnchorTag(rockUrlRoot),
                    schedule.CreatedDateTime.Value.ToShortDateString(), schedule.CreatedDateTime.Value.ToShortTimeString());
                }

                if (financialSchedule != null && schedule.ProcessedByPersonAliasId.HasValue)
                {
                    var processedByPerson = new PersonAliasService(rockContext).GetPerson(schedule.ProcessedByPersonAliasId.Value);
                    modified.AppendFormat("Imported by {0} on {1} at {2}<br/>", processedByPerson.GetAnchorTag(rockUrlRoot),
                    financialSchedule.CreatedDateTime.Value.ToShortDateString(),
                    financialSchedule.CreatedDateTime.Value.ToShortTimeString());
                }

                detailsLeft.Add("Updates", modified.ToString());
                lDetailsLeft.Text = detailsLeft.Html;

                var detailsRight = new DescriptionList();
                detailsRight.Add("Amount", schedule.Amount.FormatAsCurrency());
                detailsRight.Add("Frequency", schedule.TransactionFrequencyValue);
                detailsRight.Add("Start Date", schedule.StartDate.ToShortDateString());

                if (schedule.AccountNumberMasked != null && schedule.CurrencyTypeValue != null)
                {
                    var paymentMethodDetails = new DescriptionList();

                    var currencyType = schedule.CurrencyTypeValue;
                    if (currencyType.Guid.Equals(Rock.SystemGuid.DefinedValue.CURRENCY_TYPE_CREDIT_CARD.AsGuid()))
                    {
                        // Credit Card
                        paymentMethodDetails.Add(string.Empty, currencyType.Value + (schedule.CreditCardTypeValue != null ? (" - " + schedule.CreditCardTypeValue.Value) : string.Empty));
                        paymentMethodDetails.Add("Name on Card:", $"{schedule.FirstName} {schedule.LastName}");
                        paymentMethodDetails.Add("Account Number:", schedule.AccountNumberMasked);
                        paymentMethodDetails.Add("Expires:", schedule.ExpirationDate);
                    }
                    else
                    {
                        // ACH
                        paymentMethodDetails.Add(string.Empty, currencyType.Value);
                        paymentMethodDetails.Add("Account Number:", schedule.AccountNumberMasked);
                    }
                    detailsRight.Add("Payment Method", paymentMethodDetails.GetFormattedList("{0} {1}").AsDelimited("<br/>"));
                }
                else
                {
                    detailsRight.Add("Payment Method", "None");
                }

                // Add the link for the privousGatewayScheduleId in case previous schedule is from a gateway in rock
                var importedSchedule = new MyWellGatewayScheduleImportService(rockContext).Queryable().FirstOrDefault(x => x.Id == schedule.ImportId && x.MigratingFromFinancialGatewayId.HasValue);
                var previousSchedule = financialScheduledTransaction.Queryable().Where(x => x.GatewayScheduleId == schedule.PreviousGatewayScheduleId).FirstOrDefault();

                if (importedSchedule != null && previousSchedule != null)
                {
                    detailsRight.Add("Previous Gateway Schedule Id", $"<a href='{route}/{previousSchedule.Id}' target='_blank'>{schedule.PreviousGatewayScheduleId}</a>");
                }
                if (importedSchedule == null && previousSchedule != null)
                {
                    detailsRight.Add("Previous Gateway Schedule Id", schedule.PreviousGatewayScheduleId);
                }

                if (!string.IsNullOrEmpty(schedule.PreviousGatewayPersonIdentifier))
                {
                    detailsRight.Add("Previous Gateway Person Id", schedule.PreviousGatewayPersonIdentifier);
                }

                lDetailsRight.Text = detailsRight.Html;
            }
            else
            {
                nbEditModeMessage.Text = EditModeMessage.NotAuthorizedToEdit(FinancialTransaction.FriendlyTypeName);
            }
        }


        /// <summary>
        /// Handles the Click event of the lbCancelFinancialBatch control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void lbCancel_Click(object sender, EventArgs e)
        {
            lbCancel.Visible = false;
            lbSave.Visible = false;
            btnUpdate.Visible = true;
            pnlEditDetails.Visible = false;
        }

        /// <summary>
        /// Handles the Click event of the lbSave control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void lbSave_Click(object sender, EventArgs e)
        {
            var rockContext = new RockContext();

            MyWellGatewaySchedule schedule = GetSchedule(PageParameter("ScheduleId").AsInteger(), rockContext);
            if (schedule != null)
            {
                if (ppSelectNew.PersonId.HasValue)
                {
                    // set the AuthorizedPersonId to the person selected in the drop down
                    int authorizedPersonId = ppSelectNew.PersonId.Value;
                    int authorizedPersonAliasId = new PersonAliasService(rockContext).GetPrimaryAliasId(authorizedPersonId).Value;
                    schedule.AuthorizedPersonAliasId = authorizedPersonAliasId;
                }
                if (apDisplayedPersonalAccounts.AccountId.HasValue)
                {
                    // we only care for one account id right now
                    // check if account exists otherwise create it
                    if (schedule.AccountAllocation.Count > 0)
                    {
                        schedule.AccountAllocation.First().FinancialAccountId = apDisplayedPersonalAccounts.AccountId.Value;
                    }
                    else
                    {
                        var accountAllocationService = new MyWellGatewayScheduleAccountAllocationService(rockContext);
                        MyWellGatewayScheduleAccountAllocation accountAllocation = new MyWellGatewayScheduleAccountAllocation
                        {
                            FinancialAccountId = apDisplayedPersonalAccounts.AccountId.Value,
                            Amount = schedule.Amount,
                            ScheduleId = schedule.Id,
                            ProcessedDateTime = DateTime.Now,
                        };

                        accountAllocationService.Add(accountAllocation);
                    }
                }
                rockContext.SaveChanges();

                lbCancel.Visible = false;
                lbSave.Visible = false;
                btnUpdate.Visible = true;
                pnlEditDetails.Visible = false;

            }
        }
        /// <summary>
        /// Sets the heading information.
        /// </summary>
        /// <param name="schedule">The schedule.</param>
        private void SetHeadingInfo(MyWellGatewaySchedule schedule)
        {
            var rockContext = new RockContext();
            var financialScheduledTransaction = new FinancialScheduledTransactionService(rockContext);
            var financialSchedule = financialScheduledTransaction.Queryable().Where(x => x.GatewayScheduleId == schedule.GatewayScheduleId).FirstOrDefault();

            Dictionary<string, string> qryParams = new Dictionary<string, string>();
            qryParams.Add("ImportId", schedule.ImportId.ToString());
            lImportId.Text = string.Format("<div class='label label-info'><a href='{1}'>Import #{0}</a></div>", schedule.ImportId, LinkedPageUrl("ImportDetailPage", qryParams));
            lImportId.Visible = true;

            var mywellPortalUrl = GlobalAttributesCache.Value("MyWellGatewayPortalURL");
            qryParams.Add("MyWellPortal", schedule.ImportId.ToString());
            hlMyWellPortal.Text = string.Format("<div class='label label-info'><a  target='_blank' href='{1}/schedules/{2}'>My Well Portal</a></div>", schedule.ImportId, mywellPortalUrl, schedule.GatewayScheduleId);
            hlMyWellPortal.Visible = true;

            qryParams.Add("IsImported", schedule.ImportId.ToString());
            if (financialSchedule != null)
            {
                var qryParam = new Dictionary<string, string>();
                qryParam.Add("ScheduledTransactionId", financialSchedule.Id.ToString());
                var route = LinkedPageRoute("ScheduledTransactionDetailPage");
                ltIsActive.Text = string.Format("<div class='label {0}'>{1}</div>", getScheduleStatusLabelClass(financialSchedule.IsActive), getScheduleStatusText(financialSchedule.IsActive));
                //display the activation status instead of imported
                if (string.IsNullOrEmpty(schedule.AccountNumberMasked))
                {
                    var activated = !string.IsNullOrEmpty(financialSchedule.FinancialPaymentDetail.AccountNumberMasked);
                    lIsimported.Text = string.Format("<div class='label {0}'><a  href='{2}/{3}'>{1}</a></div>", getActivationStatusLabelClass(activated), getActivationStatusText(activated), route, financialSchedule.Id);
                }
                else
                {
                    lIsimported.Text = string.Format("<div class='label {0}'><a  href='{2}/{3}'>{1}</a></div>", getImportStatusLabelClass(schedule.IsImported), getImportStatusText(schedule.IsImported), route, financialSchedule.Id);
                }
            }
            else
            {
                lIsimported.Text = string.Format("<div class='label {0}'>{1}</div>", getImportStatusLabelClass(schedule.IsImported), getImportStatusText(schedule.IsImported));
            }
            lIsimported.Visible = true;
        }

        /// <summary>
        /// Import Status label css
        /// </summary>
        private string getImportStatusLabelClass(bool status)
        {
            if (status)
            {
                return "label label-success";
            }
            return "label label-warning"; ;
        }

        /// <summary>
        /// Schedule Status Label css.
        /// </summary>
        private string getScheduleStatusLabelClass(bool status)
        {
            if (status)
            {
                return "label label-success";
            }
            return "label label-danger"; ;
        }

        /// <summary>
        /// Activation Status Label css.
        /// </summary>
        private string getActivationStatusLabelClass(bool status)
        {
            if (status)
            {
                return "label label-success";
            }
            return "label label-danger"; ;
        }

        /// <summary>
        /// Schedule Status Text
        /// </summary>
        private string getScheduleStatusText(bool status)
        {
            if (status)
            {
                return "Active";
            }
            return "Inactive"; ;
        }

        /// <summary>
        /// Import status text
        /// </summary>
        private string getImportStatusText(bool status)
        {
            if (status)
            {
                return "Imported";
            }
            return "Import Pending"; ;
        }

        /// <summary>
        /// Activation status text
        /// </summary>
        private string getActivationStatusText(bool status)
        {
            if (status)
            {
                return "Activated";
            }
            return "Not Activated"; ;
        }
        #endregion
    }
}