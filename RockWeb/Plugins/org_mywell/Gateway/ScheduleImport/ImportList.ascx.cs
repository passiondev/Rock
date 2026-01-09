using System;
using System.ComponentModel;
using System.Linq;
using System.Web.UI;
using System.Web.UI.WebControls;
using Rock;
using Rock.Attribute;
using Rock.Data;
using Rock.Model;
using Rock.Web.UI;
using Rock.Web.UI.Controls;
using org.mywell.MyWellGateway.Model;
using System.Collections.Generic;

namespace RockWeb.Plugins.org_mywell.Gateway
{
    [DisplayName("My Well Gateway Schedule Import List")]
    [Category("My Well > Gateway")]
    [Description("My Well Gateway Schedules Import List.")]
    [LinkedPage("Detail Page", order: 0)]

    public partial class ImportList : RockBlock, ICustomGridColumns
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

            gImportList.DataKeyNames = new string[] { "Id" };
            gImportList.Actions.ShowAdd = true;
            gImportList.Actions.AddClick += gImportList_Add;
            gImportList.Actions.ShowMergeTemplate = false;
            gImportList.Actions.ShowExcelExport = false;
            gImportList.IsDeleteEnabled = true;
            gImportList.RowDataBound += gList_RowDataBound;

            var deleteField = new DeleteField();
            gImportList.Columns.Add(deleteField);
            deleteField.Click += gImportList_Delete;
        }

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Load" /> event.
        /// </summary>
        /// <param name="e">The <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnLoad(EventArgs e)
        {
            if (!Page.IsPostBack)
            {
                BindGrid();
            }
        }

        /// <summary>
        /// Restores the view-state information from a previous user control request that was saved by the <see cref="M:System.Web.UI.UserControl.SaveViewState" /> method.
        /// </summary>
        /// <param name="savedState">An <see cref="T:System.Object" /> that represents the user control state to be restored.</param>
        protected override void LoadViewState(object savedState)
        {
            base.LoadViewState(savedState);
        }

        /// <summary>
        /// Saves any user control view-state changes that have occurred since the last page postback.
        /// </summary>
        /// <returns>
        /// Returns the user control's current view state. If there is no view state associated with the control, it returns null.
        /// </returns>
        protected override object SaveViewState()
        {
            return base.SaveViewState();
        }

        #endregion

        #region Events

        /// <summary>
        /// Handles the BlockUpdated event of the control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void Block_BlockUpdated(object sender, EventArgs e)
        {
            BindGrid();
        }


        /// <summary>
        /// Handles the Delete event of the gImportList control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="RowEventArgs"/> instance containing the event data.</param>
        protected void gImportList_Delete(object sender, RowEventArgs e)
        {
            var rockContext = new RockContext();
            var scheduleImportService = new MyWellGatewayScheduleImportService(rockContext);
            var scheduleService = new MyWellGatewayScheduleService(rockContext);
            var scheduleAccountAllocationService = new MyWellGatewayScheduleAccountAllocationService(rockContext);

            var import = scheduleImportService.Get(e.RowKeyId);
            if (import != null)
            {
                rockContext.WrapTransaction(() =>
               {
                   foreach (var sch in scheduleService.Queryable()
                       .Where(t => t.ImportId == import.Id))
                   {
                       var accounts = scheduleAccountAllocationService.Queryable().Where(a => a.ScheduleId == sch.Id).ToList();
                       foreach(var acc in accounts)
                       {
                           scheduleAccountAllocationService.Delete(acc);
                       }
                       scheduleService.Delete(sch);
                   }
                   scheduleImportService.Delete(import);
                   rockContext.SaveChanges();
               });
            }
            BindGrid();
        }


        /// <summary>
        /// Handles the RowSelected event of the gImportList control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="RowEventArgs"/> instance containing the event data.</param>
        protected void gImportList_Edit(object sender, RowEventArgs e)
        {
            var myWellScheduleImport = new MyWellGatewayScheduleImportService(new RockContext()).Get(e.RowKeyId);
            if(myWellScheduleImport != null && myWellScheduleImport.IsActivated && myWellScheduleImport.IsPartial.Value)
            {
                NavigateToLinkedPage("DetailPage", "ImportId", e.RowKeyId);

                var qryParam = new Dictionary<string, string>();
                qryParam.Add("ImportId", e.RowKeyId.ToString());
                qryParam.Add("ActivationId", e.RowKeyId.ToString());
                NavigateToLinkedPage("DetailPage", qryParam);
                return;
            }
            
            NavigateToLinkedPage("DetailPage", "ImportId", e.RowKeyId);
        }

        /// <summary>
        /// Handles the Add event of the gImportList control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void gImportList_Add(object sender, EventArgs e)
        {
            NavigateToLinkedPage("DetailPage", "ImportId", 0);
        }

        #endregion

        #region Methods

        /// <summary>
        /// Handles the DataBound event of the lImportStatus control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="RowEventArgs"/> instance containing the event data.</param>
        protected void lImportStatus_DataBound(object sender, RowEventArgs e)
        {
            Literal lImportStatus = sender as Literal;
            MyWellGatewayScheduleImport importRow = e.Row.DataItem as MyWellGatewayScheduleImport;
            lImportStatus.Text = string.Format("<span class='{0}'>{1}</span>", getStatusLabelClass(importRow.Status), importRow.Status.ConvertToString());
        }

        private void gList_RowDataBound(object sender, GridViewRowEventArgs e)
        {
            if (e.Row.RowType == DataControlRowType.DataRow)
            {
                var import = e.Row.DataItem as MyWellGatewayScheduleImport;
                var totalSchedules = import.Schedules.Select(a => a.Id).Count();
                var totalMatchedSchedules = import.Schedules.Where(a => a.IsImported).Count();
                var percentImported = (int)Math.Round((double)(100 * totalMatchedSchedules) / totalSchedules);
                var totalAmountSchedules = import.Schedules.Select(a => a.Amount).Sum();
                var totalMatchedAmount = import.Schedules.Where(a => a.IsImported).Select(a => a.Amount).Sum();
                var percentAmountComplete = (int)Math.Round((double)(100 * Decimal.ToDouble(totalMatchedAmount)) / Decimal.ToDouble(totalAmountSchedules));

                if (import != null)
                {
                    var lImportedPercentage = e.Row.FindControl("lImportedPercentage") as Literal;
                    var lImported = e.Row.FindControl("lImported") as Literal;
                    var lDollars = e.Row.FindControl("lDollars") as Literal;
                    var lDollarsPercentage = e.Row.FindControl("lDollarsPercentage") as Literal;

                    if (lImportedPercentage != null)
                    {
                        lImportedPercentage.Text = $"{percentImported}%";
                    }
                    if (lImported != null)
                    {
                        lImported.Text = $"{totalMatchedSchedules} of {totalSchedules}";
                    }
                    if (lDollars != null)
                    {
                        lDollars.Text = $"{totalMatchedAmount.FormatAsCurrency()} of {totalAmountSchedules.FormatAsCurrency()}";
                    }
                    if (lDollarsPercentage != null)
                    {
                        lDollarsPercentage.Text = $"{percentAmountComplete}%";
                    }
                }
            }
        }

        /// <summary>
        /// Binds the grid.
        /// </summary>
        private void BindGrid(bool isExporting = false)
        {
            var queryable = new MyWellGatewayScheduleImportService(new RockContext()).Queryable().OrderBy(a => a.Id);
            var result = queryable.ToList();

            gImportList.DataSource = result;
            gImportList.DataBind();
        }


        /// <summary>
        /// Binds the grid.
        /// </summary>
        private string getStatusLabelClass(ImportStatus status)
        {
            switch (status)
            {
                case ImportStatus.Imported: return "label label-success";
                case ImportStatus.Pending: return "label label-warning";
            }
            return string.Empty;
        }
        #endregion

    }
}
