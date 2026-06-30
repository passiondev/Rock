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

namespace RockWeb.Plugins.org_mywell.Gateway
{
    [DisplayName("My Well Gateway Apple Pay Detail")]
    [Category("My Well > Gateway")]
    [Description("My Well Gateway Apple Pay Details.")]

    public partial class ApplePayDetail : Rock.Web.UI.RockBlock
    {
        #region Control Methods

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

            var applePayDomainId = PageParameter("ApplePayDomainId").AsInteger();
            imgMyWellLogo.ImageUrl = this.ResolveRockUrl("/Plugins/org_mywell/Assets/MyWellColor.svg");
            Uri domainUri = new Uri(GlobalAttributesCache.Get().GetValue("PublicApplicationRoot"));
            tbDomainName.Placeholder = domainUri.Host;

            if (!Page.IsPostBack)
            {
                ShowDetail(applePayDomainId);
            }

            // Add any attribute controls. 
            // This must be done here regardless of whether it is a postback so that the attribute values will get saved.
            var applePayDomain = new MyWellGatewayApplePayDomainService(new RockContext()).Get(applePayDomainId);

            if (applePayDomain == null)
            {
                applePayDomain = new MyWellGatewayApplePayDomain();
            }

            applePayDomain.LoadAttributes();
        }

        /// <summary>
        /// Handles the BlockUpdated event of the control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void Block_BlockUpdated(object sender, EventArgs e)
        {
            int applePayDomainId = hfApplePayDomaintId.ValueAsInt();
            if (applePayDomainId != 0)
            {
                ShowDetail(applePayDomainId);
            }
            else
            {
                ShowVerifyButton(null);
            }
        }

        /// <summary>
        /// Gets the verified apple pay domain object.
        /// </summary>
        /// <param name="importId">The import identifier.</param>
        /// <returns></returns>
        private MyWellGatewayApplePayDomain GetApplePayDomain(int applePayDomain, RockContext rockContext = null)
        {
            rockContext = rockContext ?? new RockContext();
            var domain = new MyWellGatewayApplePayDomainService(rockContext).Get(applePayDomain);
            return domain;
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

            int? applePayDomainId = PageParameter(pageReference, "ApplePayDomainId").AsIntegerOrNull();
            if (applePayDomainId != null)
            {
                string applePayDomain = new MyWellGatewayApplePayDomainService(new RockContext())
                    .Queryable().Where(b => b.Id == applePayDomainId.Value)
                    .Select(b => b.DomainName)
                    .FirstOrDefault();

                if (!string.IsNullOrWhiteSpace(applePayDomain))
                {
                    breadCrumbs.Add(new BreadCrumb(applePayDomain, pageReference));
                }
                else
                {
                    breadCrumbs.Add(new BreadCrumb("Apple Domain Verification", pageReference));
                }
            }
            else
            {
                // don't show a breadcrumb if we don't have a pageparam to work with
            }

            return breadCrumbs;
        }

        #endregion

        #region Events

        /// <summary>
        /// Shows the detail.
        /// </summary>
        /// <param name="applePayDomainId">The apple pay domain identifier.</param>
        public void ShowDetail(int applePayDomainId)
        {
            var applePayDomain = GetApplePayDomain(applePayDomainId);

            if (applePayDomain == null)
            {
                ShowVerifyButton(null);
                return;
            }

            lDomainName.Text = applePayDomain.DomainName;
            lMyWellApplePayId.Text = applePayDomain.MerchantId;
            lBenevityId.Text = applePayDomain.BenevityId;

            if (!applePayDomain.IsVerified)
            {
                ShowVerifyButton(applePayDomain, true);
                return;
            }

            pnlCheckStatus.Visible = true;
            pnlApplePayId.Visible = true;
            lDescription.Text = " <div class='mt-4 alert alert-success shadow-lg'>Your domain is verified and is configured for Apple Pay. Simply enable Apple Pay under the My Well Financial Gateway and start processing donations with Apple Pay.</div>";
            pnVerifyFields.Visible = false;
            pnlVerifyMode.Visible = false;
        }

        private void ReVerifyDomain(MyWellGatewayApplePayDomain applePayDomain)
        {
            var reVerifyText = " <div class='mt-4 alert alert-danger shadow-lg'>The domain below needs to be verified again to use Apple Pay.</div>";

            pnlCheckStatus.Visible = false;
            pnlVerifyMode.Visible = true;
            tbDomainName.Enabled = false;
            tbBenevityId.Enabled = false;
            fgFinancialGateway.Enabled = false;
            tbDomainName.Text = lDomainName.Text;
            tbBenevityId.Text = lBenevityId.Text;
            lDescription.Text = reVerifyText;
            fgFinancialGateway.SelectedValue = applePayDomain.FinancialGatewayId.ToString();

            var rockContext = new RockContext();
            var storedApplePayDomain = new MyWellGatewayApplePayDomainService(rockContext).Get(applePayDomain.Id);

            if (storedApplePayDomain != null)
            {
                storedApplePayDomain.IsVerified = false;
                rockContext.SaveChanges();
            }
        }

        /// <summary>
        /// Shows the verify edit details.
        /// </summary>
        public void ShowVerifyButton(MyWellGatewayApplePayDomain applePayDomain, bool? reVerification = false)
        {
            // Initally the organization will not have an Apple Pay Merchant Id and will need to go through verifying their domain
            pnlApplePayId.Visible = false;
            pnlCheckStatus.Visible = false;
            lDescription.Text = "<p>Before you start using Apple Pay, your organization needs to be added to Benevity's Database. Click <a href='https://help.mywell.org/how-to-add-your-organization-to-benevitys-database' _target='_blank'>here</a> to add your organization. Once the process is complete, click below to verify your domain with Apple and start using Apple Pay with the My Well Gateway.</p>";

            pnVerifyFields.Visible = true;
            pnlVerifyMode.Visible = true;

            // If the reverification is required
            if (reVerification.Value)
            {
                ReVerifyDomain(applePayDomain);
            }

            var myWellFinancialGatewayEntityId = new FinancialGatewayService(new RockContext()).Queryable().Where(x => x.EntityType.Name == "org.mywell.MyWellGateway.MyWellGateway").Select(x => x.EntityTypeId).FirstOrDefault();

            // we want to only show the My Well gatweay for the target gateway dropdown
            var financialTargetGatewayCount = fgFinancialGateway.Items.Count;

            // go through all the gateways and make sure we only show the My Well Gateway for the target gateway dopdown
            // note: an org can have multiple gateways as the My Well gateway so we want to show all of them
            for (int i = financialTargetGatewayCount - 1; i >= 0; i--)
            {
                var item = fgFinancialGateway.Items[i];
                var itemValue = item.Value.AsIntegerOrNull();
                var financialGateway = new FinancialGatewayService(new RockContext()).Queryable().Where(x => x.Id == itemValue).FirstOrDefault();

                if (financialGateway != null && financialGateway.EntityTypeId != myWellFinancialGatewayEntityId)
                {
                    fgFinancialGateway.Items.Remove(item);
                }
            }
        }

        /// <summary>
        /// Handles the Click event of the btnVerifyDomain control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void btnVerifyDomain_Click(object sender, EventArgs e)
        {
            pnErrorMessage.Visible = false;
            string errorMessage = string.Empty;
            using (var rockContext = new RockContext())
            {
                var selectedFinacialGatewayId = fgFinancialGateway.SelectedValueAsInt();
                if (selectedFinacialGatewayId.HasValue)
                {
                    var targetFinancialGateway = new FinancialGatewayService(rockContext).Get(selectedFinacialGatewayId.Value);
                    var applePayDomainService = new MyWellGatewayApplePayDomainService(rockContext);

                    MyWellGateway gateway = new MyWellGateway();

                    String[] domains = { tbDomainName.Text };

                    // rename the web.config.mywell to web.config
                    // others plugins might use the .well-known directory and we don't want to interfier with other plugins
                    string appleOriginalFile = System.Web.HttpContext.Current.Server.MapPath("~/Plugins/org_mywell/Gateway/Config/ApplePay/appleMerchantDomainVerification");
                    string appleRenamedFile = System.Web.HttpContext.Current.Server.MapPath("~/.well-known/apple-developer-merchantid-domain-association");

                    string mywellWebConfig = System.Web.HttpContext.Current.Server.MapPath("~/Plugins/org_mywell/Gateway/Config/ApplePay/web.config.mywell");
                    string renamedWebConfig = System.Web.HttpContext.Current.Server.MapPath("~/.well-known/web.config");

                    // we don't want to rename any existing files if they exist in this directory, we just want to tell the user
                    if(File.Exists(renamedWebConfig))
                    {
                        lErrorMessageTitle.Text = "Failed to create file ~/.well-known/web.config. There is already an existing file with this name. Please rename the existing file before verifying your domain.";
                        pnErrorMessage.Visible = true;
                        return;
                    }

                    bool wellKnownDirectory = System.IO.Directory.Exists(Server.MapPath("~/.well-known"));

                    if (!wellKnownDirectory)
                    {
                        System.IO.Directory.CreateDirectory(Server.MapPath("~/.well-known"));
                    }

                    System.IO.File.Copy(mywellWebConfig, renamedWebConfig);
                    System.IO.File.Copy(appleOriginalFile, appleRenamedFile, true);

                    if (targetFinancialGateway != null)
                    {
                        string orgName = GlobalAttributesCache.Get().GetValue("OrganizationName");
                        var applePayData = new CreateApplePayDomainData
                        {
                            DomainNames = domains,
                            BenevityId = tbBenevityId.Text
                        };

                        var response = gateway.RegisterApplePayDomains(targetFinancialGateway, applePayData, out errorMessage);
                        if (errorMessage.IsNotNullOrWhiteSpace())
                        {
                            lErrorMessageTitle.Text = "<h3 class='mt-0'><i class='fa fa-exclamation-triangle mr-2 text-red-500'></i>Error Verifying Domain.</h3> <p>If you continue to have this issue please reach out to our support team.</p>";
                            lErrorBody.Text = errorMessage;
                            pnErrorMessage.Visible = true;

                            // rename the web.config back to orginial filename since we don't want to interfier with other plugins 
                            System.IO.File.Delete(renamedWebConfig);
                            System.IO.File.Delete(appleRenamedFile);
                            return;
                        }

                        // if this domain was previously enabled, we just want to update it
                        var registeringDomain = response.DomainNames.FirstOrDefault();
                        var existingApplePayDomain = applePayDomainService.Queryable().Where(d => d.DomainName == registeringDomain && d.FinancialGatewayId == targetFinancialGateway.Id).FirstOrDefault();
                        var applePayDomainId = 0;
                        if (existingApplePayDomain == null)
                        {
                            var applePayDomain = new MyWellGatewayApplePayDomain
                            {
                                DomainName = registeringDomain,
                                BenevityId = tbBenevityId.Text,
                                MerchantId = response.Id,
                                FinancialGateway = targetFinancialGateway,
                                IsVerified = true,

                            };
                            applePayDomainService.Add(applePayDomain);
                            rockContext.SaveChanges();
                            applePayDomainId = applePayDomain.Id;
                        }
                        else
                        {
                            existingApplePayDomain.IsVerified = true;
                            applePayDomainId = existingApplePayDomain.Id;
                            rockContext.SaveChanges();
                        }

                        // rename the web.config back to orginial filename since we don't want to interfier with other plugins 
                        System.IO.File.Delete(renamedWebConfig);
                        System.IO.File.Delete(appleRenamedFile);
                        var pageReference = CurrentPageReference;
                        pageReference.Parameters.AddOrReplace("ApplePayDomainId", applePayDomainId.ToString());
                        NavigateToPage(pageReference);
                    }
                }
            }
        }

        /// <summary>
        /// Handles the Click event of the  btnCheckStatus control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void btnCheckStatus_Click(object sender, EventArgs e)
        {
            // Check to make sure the domain is still verified. Otherwise we will need to verify it again
            MyWellGateway gateway = new MyWellGateway();
            string errorMessage = string.Empty;

            var applePayDomainId = PageParameter("ApplePayDomainId").AsInteger();

            var applePayDomain = new MyWellGatewayApplePayDomainService(new RockContext()).Get(applePayDomainId);

            var response = gateway.GetApplePayVerifiedDomains(applePayDomain.FinancialGateway, out errorMessage);
            if (errorMessage.IsNotNullOrWhiteSpace())
            {
                // if there is an error, that means there are no verified domains for this organization
                ShowVerifyButton(applePayDomain, true);
                return;
            }

            if (!response.DomainNames.Contains(applePayDomain.DomainName))
            {
                ShowVerifyButton(applePayDomain, true);
                return;
            }

            lDescription.Text = " <div class='mt-4 alert alert-success shadow-lg'>Your domain is still valid to accept Apple Pay.</div>";
        }
    }
    #endregion
}



