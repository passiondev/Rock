using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Data.Entity;
using System.Linq;
using System.Web.UI;
using System.Web.UI.WebControls;
using Rock;
using Rock.Attribute;
using Rock.Constants;
using Rock.Data;
using Rock.Model;
using Rock.Web.Cache;
using Rock.Web.UI;
using Rock.Web.UI.Controls;
using org.mywell.MyWellGateway.Model;

namespace RockWeb.Plugins.org_mywell.Gateway
{
    /// <summary>
    /// Transaction List
    /// </summary>
    /// <seealso cref="Rock.Web.UI.RockBlock" />
    /// <seealso cref="Rock.Web.UI.ISecondaryBlock" />
    /// <seealso cref="System.Web.UI.IPostBackEventHandler" />
    /// <seealso cref="Rock.Web.UI.ICustomGridColumns" />
    [DisplayName("My Well Gateway Imported Schedule List")]
    [Category("My Well > Gateway")]
    [Description("My Well Gateway Imported Schedules.")]

    [LinkedPage("Detail Page", order: 0)]

    public partial class ScheduleList : Rock.Web.UI.RockBlock, ICustomGridColumns
    {
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

            // Using two filters since export to excel doesn't work well with one filter
            // Filter config for import screen
            gfImportSettings.ApplyFilterClick += gfImportSettings_ApplyFilterClick;
            gfImportSettings.ClearFilterClick += gfImportSettings_ClearFilterClick;
            gfImportSettings.DisplayFilterValue += gfSettings_DisplayFilterValue;

            // Filter config for activation screen
            gfActivationSettings.ApplyFilterClick += gfActivationSettings_ApplyFilterClick;
            gfActivationSettings.ClearFilterClick += gfActivationSettings_ClearFilterClick;
            gfActivationSettings.DisplayFilterValue += gfSettings_DisplayFilterValue;

            gImportList.DataKeyNames = new string[] { "Id" };
            gImportList.Actions.ShowMergeTemplate = false;
            gImportList.Actions.ShowMergePerson = false;
            gImportList.IsDeleteEnabled = true;

            // Reguired for communication to work
            gImportList.GridRebind += gList_GridRebind;
            gImportList.RowDataBound += gList_RowDataBound;

            // Check which screen is active and reset the filters and enable the specific status
            var activationId = PageParameter("ActivationId").AsInteger();
            if (activationId > 0)
            {
                gfImportSettings.Visible = false;
                gfActivationSettings.Visible = true;
                gfImportSettings.DeleteUserPreferences();
                ddlActivationStatus.Items.Add("Activated");
                ddlActivationStatus.Items.Add("Not Activated");
                ddlActivationStatus.Items.Add("Canceled");
            }
            else
            {
                gfImportSettings.Visible = true;
                gfActivationSettings.Visible = false;
                gfActivationSettings.DeleteUserPreferences();
                ddlImportStatus.Items.Add("Imported");
                ddlImportStatus.Items.Add("Import Pending");
            }

            // Bind the frequency dropdown
            BindFrequencyDropDown(dvpActivationFrequency);
            BindFrequencyDropDown(dvpImportFrequency);

            // Bind the currency dropdown
            BindCurrencyDropDown(dvpActivationCurrencyType);
            BindCurrencyDropDown(dvpImportCurrencyType);
        }

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Load" /> event.
        /// </summary>
        /// <param name="e">The <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);

            var importId = PageParameter("ImportId").AsInteger();
            hfImportId.Value = importId.ToString();

            // Set the view mode depending which navigation item was clicked on
            var activationId = PageParameter("ActivationId").AsInteger();
            if (activationId > 0)
            {
                hfScheduleViewMode.Value = "Activation";
            }
            else
            {
                hfScheduleViewMode.Value = "Import";
            }

            if (!Page.IsPostBack)
            {
                if (importId > 0)
                {
                    BindFilter();
                    BindGrid(importId);
                }
                else
                {
                    // If the Import is 0 we don't want to show the schedule list
                    pnlImportList.Visible = false;
                }
            }
        }
        #endregion

        #region Events

        /// <summary>
        /// Gfs the settings_ display filter value.
        /// </summary>
        /// <param name="sender">The sender.</param>
        /// <param name="e">The e.</param>
        protected void gfSettings_DisplayFilterValue(object sender, GridFilter.DisplayFilterValueArgs e)
        {
            switch (e.Key)
            {
                case "Currency Type":
                case "Credit Card Type":
                case "Frequency":
                    int definedValueId = 0;
                    if (int.TryParse(e.Value, out definedValueId))
                    {
                        var definedValue = DefinedValueCache.Get(definedValueId);
                        if (definedValue != null)
                        {
                            e.Value = definedValue.Value;
                        }
                    }
                    break;
                case "Status":
                    break;
                default:
                    e.Value = string.Empty;
                    break;
            }
        }

        /// <summary>
        /// Handles the ApplyFilterClick event of the gfActivationSettings control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs" /> instance containing the event data.</param>
        protected void gfActivationSettings_ApplyFilterClick(object sender, EventArgs e)
        {
            gfActivationSettings.SaveUserPreference("Frequency", dvpActivationFrequency.SelectedValue != All.Id.ToString() ? dvpActivationFrequency.SelectedValue : string.Empty);
            gfActivationSettings.SaveUserPreference("Currency Type", dvpActivationCurrencyType.SelectedValue != All.Id.ToString() ? dvpActivationCurrencyType.SelectedValue : string.Empty);
            gfActivationSettings.SaveUserPreference("Credit Card Type", dvpActivationCreditCardType.SelectedValue != All.Id.ToString() ? dvpActivationCreditCardType.SelectedValue : string.Empty);
            gfActivationSettings.SaveUserPreference("Status", ddlActivationStatus.SelectedValue);
            gfActivationSettings.SaveUserPreference("Schedule Id", tbActivationScheduleId.Text);
            gfActivationSettings.SaveUserPreference("Activated", drpActivatedDates.DelimitedValues);
            gfActivationSettings.SaveUserPreference("Previous Schedule Id", tbActivationPreviousScheduleId.Text);

            BindGrid(hfImportId.ValueAsInt());
        }

        /// <summary>
        /// Handles the ApplyFilterClick event of the gfImportSettings control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs" /> instance containing the event data.</param>
        protected void gfImportSettings_ApplyFilterClick(object sender, EventArgs e)
        {
            gfImportSettings.SaveUserPreference("Frequency", dvpImportFrequency.SelectedValue != All.Id.ToString() ? dvpImportFrequency.SelectedValue : string.Empty);
            gfImportSettings.SaveUserPreference("Currency Type", dvpImportCurrencyType.SelectedValue != All.Id.ToString() ? dvpImportCurrencyType.SelectedValue : string.Empty);
            gfImportSettings.SaveUserPreference("Credit Card Type", dvpImportCreditCardType.SelectedValue != All.Id.ToString() ? dvpImportCreditCardType.SelectedValue : string.Empty);
            gfImportSettings.SaveUserPreference("Status", ddlImportStatus.SelectedValue);
            gfImportSettings.SaveUserPreference("Schedule Id", tbImportScheduleId.Text);
            gfImportSettings.SaveUserPreference("Previous Schedule Id", tbImportPreviousScheduleId.Text);
            BindGrid(hfImportId.ValueAsInt());
        }

        /// <summary>
        /// Handles the ApplyFilterClick event of the gfActivationSettings control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs" /> instance containing the event data.</param>
        protected void gfActivationSettings_ClearFilterClick(object sender, EventArgs e)
        {
            gfActivationSettings.DeleteUserPreferences();
            BindFilter();
        }

        /// <summary>
        /// Handles the ApplyFilterClick event of the gfImportSettings control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs" /> instance containing the event data.</param>
        protected void gfImportSettings_ClearFilterClick(object sender, EventArgs e)
        {
            gfImportSettings.DeleteUserPreferences();
            BindFilter();
        }

        /// <summary>
        /// Handles the BlockUpdated event of the control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void Block_BlockUpdated(object sender, EventArgs e)
        {
            BindGrid(hfImportId.ValueAsInt());
        }

        /// <summary>
        /// Handles the RowSelected event of the gImportList control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="RowEventArgs"/> instance containing the event data.</param>
        protected void gImportList_Edit(object sender, RowEventArgs e)
        {
            Dictionary<string, string> qryParams = new Dictionary<string, string>();
            qryParams.Add("ImportId", hfImportId.Value);
            qryParams.Add("ScheduleId", e.RowKeyId.ToString());
            NavigateToLinkedPage("DetailPage", qryParams);
        }
        #endregion

        #region Methods

        /// <summary>
        /// Handles the RowSelected event of the gImportList control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="RowEventArgs"/> instance containing the event data.</param>
        private void gList_GridRebind(object sender, EventArgs e)
        {
            gImportList.ExportTitleName = "My Well Schedules";
            gImportList.ExportFilename = "My Well Schedules";

            BindGrid(hfImportId.ValueAsInt());
        }

        /// <summary>
        /// Handles the DataBound event of the gImportList control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="RowEventArgs"/> instance containing the event data.</param>
        private void gList_RowDataBound(object sender, GridViewRowEventArgs e)
        {
            gImportList.ExportFilename = "My Well Gateway Schedules";
            gImportList.ExportSource = ExcelExportSource.DataSource;

            if (e.Row.RowType == DataControlRowType.DataRow)
            {
                var schedule = e.Row.DataItem as MyWellGatewaySchedule;

                if (schedule != null)
                {
                    var lTotalAmount = e.Row.FindControl("lTotalAmount") as Literal;
                    var lPerson = e.Row.FindControl("lPerson") as Literal;
                    var lPersonId = e.Row.FindControl("lPersonId") as Literal;
                    if (lTotalAmount != null)
                    {
                        lTotalAmount.Text = schedule.Amount.FormatAsCurrency();
                    }
                    if (lPerson != null)
                    {
                        lPerson.Text = $"{schedule.LastName}, {schedule.FirstName}";
                    }
                }
            }
        }

        /// <summary>
        /// Handles the DataBound event of the lImportStatus control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="RowEventArgs"/> instance containing the event data.</param>
        protected void lImportStatus_DataBound(object sender, RowEventArgs e)
        {
            Literal lImportStatus = sender as Literal;
            MyWellGatewaySchedule importRow = e.Row.DataItem as MyWellGatewaySchedule;
            if (hfScheduleViewMode.Value == "Activation")
            {
                var claimStatus = "Not Activated";
                var claimLabelClass = "label label-danger";

                if (importRow.ActivatedDateTime.HasValue)
                {

                    claimStatus = "Activated";
                    claimLabelClass = "label label-success";
                }

                if (importRow.FinancialScheduledTransaction != null && !importRow.FinancialScheduledTransaction.IsActive)
                {

                    claimStatus = "Canceled";
                    claimLabelClass = "label label-warning";
                }

                lImportStatus.Text = string.Format("<span class='{0}'>{1}</span>", claimLabelClass, claimStatus);
            }
            else
            {
                lImportStatus.Text = string.Format("<span class='{0}'>{1}</span>", getStatusLabelClass(importRow.IsImported), getStatusText(importRow.IsImported));
            }
        }

        /// <summary>
        /// Binds the filter.
        /// </summary>
        private void BindFilter()
        {
            var activationId = PageParameter("ActivationId").AsInteger();
            if (activationId > 0)
            {
                dvpActivationFrequency.SetValue(gfActivationSettings.GetUserPreference("Frequency"));
                ddlActivationStatus.SetValue(gfActivationSettings.GetUserPreference("Status"));
                tbActivationScheduleId.Text = gfActivationSettings.GetUserPreference("Schedule Id");
                dvpActivationCurrencyType.SetValue(gfActivationSettings.GetUserPreference("Currency Type"));
                drpActivatedDates.DelimitedValues = gfActivationSettings.GetUserPreference("Activated");
                tbActivationPreviousScheduleId.Text = gfActivationSettings.GetUserPreference("Previous Schedule Id");
                BindDefinedTypeDropdown(dvpActivationCreditCardType, new Guid(Rock.SystemGuid.DefinedType.FINANCIAL_CREDIT_CARD_TYPE), "Credit Card Type", gfActivationSettings);
            }
            else
            {
                dvpImportFrequency.SetValue(gfImportSettings.GetUserPreference("Frequency"));
                ddlImportStatus.SetValue(gfImportSettings.GetUserPreference("Status"));
                tbImportScheduleId.Text = gfImportSettings.GetUserPreference("Schedule Id");
                dvpImportCurrencyType.SetValue(gfImportSettings.GetUserPreference("Currency Type"));
                tbImportPreviousScheduleId.Text = gfImportSettings.GetUserPreference("Previous Schedule Id");
                BindDefinedTypeDropdown(dvpImportCreditCardType, new Guid(Rock.SystemGuid.DefinedType.FINANCIAL_CREDIT_CARD_TYPE), "Credit Card Type", gfImportSettings);
            }


        }

        /// <summary>
        /// Binds the grid.
        /// </summary>
        private void BindGrid(int importId)
        {
            using (var rockContext = new RockContext())
            {
                var importStatus = new MyWellGatewayScheduleImportService(rockContext).Queryable().Where(x => x.Id == importId).Select(x => x.Status).FirstOrDefault();

                var qry = new MyWellGatewayScheduleService(rockContext).Queryable().Where(x => x.ImportId == importId);

                // If all schedules are imported then we can enable the communication
                if (importStatus == ImportStatus.Imported)
                {
                    qry = new MyWellGatewayScheduleService(rockContext).Queryable("AuthorizedPersonAlias.Person").AsNoTracking().Where(x => x.ImportId == importId);
                }

                // check if schedules were imported then show the communication
                var isImported = qry.All(x => x.IsImported == true);
                if (isImported)
                {
                    gImportList.PersonIdField = "AuthorizedPersonAlias.PersonId";
                }

                string status = String.Empty;
                int? frequencyTypeId;
                string scheduleId = String.Empty;
                int? currencyTypeId;
                int? creditcardTypeId;
                string previousScheduleId = String.Empty;
                var drp = new DateRangePicker();


                // Get filters from either activation or import screens depending what page it's coming from
                var activationId = PageParameter("ActivationId").AsInteger();
                if (activationId > 0)
                {
                    status = gfActivationSettings.GetUserPreference("Status");
                    frequencyTypeId = gfActivationSettings.GetUserPreference("Frequency").AsIntegerOrNull();
                    scheduleId = gfActivationSettings.GetUserPreference("Schedule Id");
                    currencyTypeId = gfActivationSettings.GetUserPreference("Currency Type").AsIntegerOrNull();
                    creditcardTypeId = gfActivationSettings.GetUserPreference("Credit Card Type").AsIntegerOrNull();
                    drp.DelimitedValues = gfActivationSettings.GetUserPreference("Activated");
                    previousScheduleId = gfActivationSettings.GetUserPreference("Previous Schedule Id");
                }
                else
                {
                    gImportList.Columns.RemoveAt(8);
                    gImportList.Columns.RemoveAt(7);
                    status = gfImportSettings.GetUserPreference("Status");
                    frequencyTypeId = gfImportSettings.GetUserPreference("Frequency").AsIntegerOrNull();
                    scheduleId = gfImportSettings.GetUserPreference("Schedule Id");
                    previousScheduleId = gfImportSettings.GetUserPreference("Previous Schedule Id");
                    currencyTypeId = gfImportSettings.GetUserPreference("Currency Type").AsIntegerOrNull();
                    creditcardTypeId = gfImportSettings.GetUserPreference("Credit Card Type").AsIntegerOrNull();
                }

                // activated date filter
                if (drp.LowerValue.HasValue)
                {
                    qry = qry.Where(t => t.ActivatedDateTime >= drp.LowerValue.Value);
                }
                if (drp.UpperValue.HasValue)
                {
                    DateTime upperDate = drp.UpperValue.Value.Date.AddDays(1);
                    qry = qry.Where(t => t.ActivatedDateTime < upperDate);
                }

                // status filter
                if (!string.IsNullOrWhiteSpace(status))
                {
                    if (status == "Import Pending")
                    {
                        qry = qry.Where(x => x.IsImported == false);
                    }
                    else if (status == "Imported")
                    {
                        qry = qry.Where(x => x.IsImported == true);
                    }
                    else if (status == "Activated")
                    {
                        qry = qry.Where(x => x.ActivatedDateTime.HasValue);
                    }
                    else if (status == "Not Activated")
                    {
                        qry = qry.Where(x => x.ActivatedDateTime.HasValue == false);
                    }
                    else if (status == "Canceled")
                    {
                        qry = qry.Where(x => x.FinancialScheduledTransaction.IsActive == false);
                    }
                }

                //currency type filter
                if (currencyTypeId.HasValue)
                {
                    qry = qry.Where(x => x.CurrencyTypeValueId == currencyTypeId);
                }

                //credit card type filter
                if (creditcardTypeId.HasValue)
                {
                    qry = qry.Where(x => x.CreditCardTypeValueId == creditcardTypeId);
                }

                //Schedule Id filter
                if (!string.IsNullOrWhiteSpace(scheduleId))
                {
                    qry = qry.Where(x => x.GatewayScheduleId == scheduleId);
                }

                //Previous Schedule Id filter
                if (!string.IsNullOrWhiteSpace(previousScheduleId))
                {
                    qry = qry.Where(x => x.PreviousGatewayScheduleId == previousScheduleId);
                }

                // Frequency
                if (frequencyTypeId.HasValue)
                {
                    qry = qry.Where(x => x.TransactionFrequencyValueId == frequencyTypeId.Value);
                }

                // Sorting
                SortProperty sortProperty = gImportList.SortProperty;
                if (sortProperty != null)
                {
                    if (sortProperty.Property == "Person")
                    {
                        if (sortProperty.Direction == SortDirection.Descending)
                        {
                            qry = qry.OrderByDescending(q => q.LastName).ThenBy(q => q.FirstName);
                        }
                        else
                        {
                            qry = qry.OrderBy(q => q.LastName).ThenBy(q => q.FirstName);
                        }
                    }
                    else if (sortProperty.Property == "ActivatedDateTime")
                    {
                        if (sortProperty.Direction == SortDirection.Descending)
                        {
                            qry = qry.OrderByDescending(q => q.ActivatedDateTime.Value);
                        }
                        else
                        {
                            qry = qry.OrderBy(q => q.ActivatedDateTime.Value);
                        }
                    }
                    else
                    {
                        qry = qry.Sort(sortProperty);
                    }
                }
                else
                {
                    qry = qry.OrderByDescending(d => d.CreatedDateTime);
                }

                gImportList.DataSource = qry.ToList();
                gImportList.DataBind();
            }
        }

        /// <summary>
        /// Binds the defined type dropdown.
        /// </summary>
        /// <param name="ListControl">The list control.</param>
        /// <param name="definedTypeGuid">The defined type GUID.</param>
        /// <param name="userPreferenceKey">The user preference key.</param>
        /// <param name="grid">The grid.</param>
        private void BindDefinedTypeDropdown(DefinedValuePicker dvpControl, Guid definedTypeGuid, string userPreferenceKey, GridFilter grid)
        {
            dvpControl.DefinedTypeId = DefinedTypeCache.Get(definedTypeGuid).Id;
            dvpControl.SelectedValue = grid.GetUserPreference(userPreferenceKey);
        }

        /// <summary>
        /// Binds the frequency dropdown list.
        /// </summary>
        /// <param name="dropDownList">The dropdown list.</param>
        private void BindFrequencyDropDown(RockDropDownList dropDownList)
        {
            dropDownList.Items.Add(new ListItem { Text = "One-Time", Value = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.TRANSACTION_FREQUENCY_ONE_TIME.AsGuid()).Id.ToString() });
            dropDownList.Items.Add(new ListItem { Text = "Weekly", Value = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.TRANSACTION_FREQUENCY_WEEKLY.AsGuid()).Id.ToString() });
            dropDownList.Items.Add(new ListItem { Text = "Bi-Weekly", Value = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.TRANSACTION_FREQUENCY_BIWEEKLY.AsGuid()).Id.ToString() });
            dropDownList.Items.Add(new ListItem { Text = "1st and 15th", Value = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.TRANSACTION_FREQUENCY_FIRST_AND_FIFTEENTH.AsGuid()).Id.ToString() });
            dropDownList.Items.Add(new ListItem { Text = "Monthly", Value = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.TRANSACTION_FREQUENCY_MONTHLY.AsGuid()).Id.ToString() });
        }

        /// <summary>
        /// Binds the currency dropdown list.
        /// </summary>
        /// <param name="dropDownList">The dropdown list.</param>
        private void BindCurrencyDropDown(RockDropDownList dropDownList)
        {
            dropDownList.Items.Add(new ListItem { Text = "ACH", Value = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.CURRENCY_TYPE_ACH.AsGuid()).Id.ToString() });
            dropDownList.Items.Add(new ListItem { Text = "Credit Card", Value = DefinedValueCache.Get(Rock.SystemGuid.DefinedValue.CURRENCY_TYPE_CREDIT_CARD.AsGuid()).Id.ToString() });
        }

        /// <summary>
        /// Binds the grid.
        /// </summary>
        private string getStatusLabelClass(bool status)
        {
            if (status)
            {
                return "label label-success";
            }
            return "label label-warning"; ;
        }

        /// <summary>
        /// Binds the grid.
        /// </summary>
        private string getStatusText(bool status)
        {
            if (status)
            {
                return "Imported";
            }
            return "Import Pending"; ;
        }

        #endregion
    }
}