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
using org.mywell.MyWellGateway;

namespace RockWeb.Plugins.org_mywell.Gateway
{
    [DisplayName("My Well Gateway Apple iOS List.")]
    [Category("My Well > Gateway")]
    [Description("My Well Gateway Apple iOS List.")]
    [LinkedPage("Detail Page", order: 0)]

    public partial class ApplePayMobileList : RockBlock, ICustomGridColumns
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

            gApplePayList.DataKeyNames = new string[] { "Id" };
            gApplePayList.Actions.ShowAdd = true;
            gApplePayList.Actions.AddClick += gApplePayList_Add;
            gApplePayList.Actions.ShowMergeTemplate = false;
            gApplePayList.Actions.ShowExcelExport = false;
            gApplePayList.IsDeleteEnabled = true;
            gApplePayList.RowDataBound += gApplePayList_RowDataBound;

            var deleteField = new DeleteField();
            gApplePayList.Columns.Add(deleteField);
            deleteField.Click += gApplePayList_Delete;
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
        /// Handles the Delete event of the gApplePayList control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="RowEventArgs"/> instance containing the event data.</param>
        protected void gApplePayList_Delete(object sender, RowEventArgs e)
        {
            var rockContext = new RockContext();
            var appleCertificateService = new MyWellGatewayAppleCertificateService(rockContext);
            var applePayDomain = appleCertificateService.Get(e.RowKeyId);
            string errorMessage = string.Empty;

            if (applePayDomain != null)
            {
                rockContext.WrapTransaction(() =>
               {
                   MyWellGateway myWellGateway = new MyWellGateway();
                   string certificatId = applePayDomain.CertificateId;

                   var response = myWellGateway.DeleteApplePayCertificateRequest(applePayDomain.FinancialGateway, certificatId, out errorMessage);

                   if (response == false || errorMessage.IsNotNullOrWhiteSpace())
                   {
                       nbWarningMessage.Text = "Failed to delete the apple pay certificate.";
                       return;
                   }

                   appleCertificateService.Delete(applePayDomain);
                   rockContext.SaveChanges();
               });
            }
            BindGrid();
        }

        /// <summary>
        /// Handles the Add event of the gApplePayList control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void gApplePayList_Add(object sender, EventArgs e)
        {
            NavigateToLinkedPage("DetailPage");
        }

        #endregion

        #region Methods

        private void gApplePayList_RowDataBound(object sender, GridViewRowEventArgs e)
        {
            if (e.Row.RowType == DataControlRowType.DataRow)
            {
                var applePayDomain = e.Row.DataItem as MyWellGatewayAppleCertificate;
                var financialGatewayName = applePayDomain.FinancialGateway.Name;
                if (applePayDomain != null)
                {
                    var lFinancialGatewayName = e.Row.FindControl("lFinancialGatewayName") as Literal;

                    if (lFinancialGatewayName != null)
                    {
                        lFinancialGatewayName.Text = financialGatewayName;
                    }
                }
            }
        }

        /// <summary>
        /// Handles the DataBound event of the gApplePayList control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="RowEventArgs"/> instance containing the event data.</param>
        protected void lVerifiedStatus_DataBound(object sender, RowEventArgs e)
        {
            Literal lVerificationtStatus = sender as Literal;
            MyWellGatewayApplePayDomain importRow = e.Row.DataItem as MyWellGatewayApplePayDomain;
     
        }


        /// <summary>
        /// Binds the grid.
        /// </summary>
        private void BindGrid()
        {
            var queryable = new MyWellGatewayAppleCertificateService(new RockContext()).Queryable().OrderBy(a => a.Id);
            var result = queryable.ToList();

            gApplePayList.DataSource = result;
            gApplePayList.DataBind();
        }

        #endregion

    }
}
