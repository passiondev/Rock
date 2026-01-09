using System;
using System.ComponentModel;
using org.mywell.MyWellGateway.Types;
using org.mywell.MyWellGateway;
using System.Web.UI;
using Rock;
using Rock.Attribute;
using Rock.Data;
using Rock.Model;
using Rock.Web.Cache;
using System.Linq;

namespace RockWeb.Plugins.org_mywell.Gateway
{
    [DisplayName("My Well Gateway Apple Pay Configuration")]
    [Category("My Well > Apple Pay Configuration")]
    [Description("Apple Pay Configuration for the My Well Gateway.")]

    [TextField(
        "Override Domains",
        Description = "The rock domains to allow apple pay on. This will override the domain verified from the PublicApplicationRoot Global Attribute.",
        IsRequired = false,
        Key = AttributeKey.OvverrideDomains)]

    public partial class ApplePayConfiguration : Rock.Web.UI.RockBlock
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
            public const string OvverrideDomains = "OvverrideDomains";
        }

        #endregion Attribute Keys

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Init" /> event.
        /// </summary>
        /// <param name="e">An <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnInit(EventArgs e)
        {
            base.OnInit(e);

        }

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Load" /> event.
        /// </summary>
        /// <param name="e">The <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnLoad(EventArgs e)
        {
            base.OnLoad(e);

            //Rock.Web.SystemSettings.SetValue(org.mywell.MyWellGateway.SystemKey.MyWellGatewayConfiguration.APPLEPAY_CONFIGURATION_KEY, null);

            if (!Page.IsPostBack)
            {

                Uri domainUri = new Uri(GlobalAttributesCache.Get().GetValue("PublicApplicationRoot"));

                imgMyWellLogo.ImageUrl = this.ResolveRockUrl("/Plugins/org_mywell/Assets/MyWellColor.svg");
                lExternalRockAddress.Text = domainUri.Host;

                var myWellGatewayApplePayConfiguration = Rock.Web.SystemSettings.GetValue(org.mywell.MyWellGateway.SystemKey.MyWellGatewayConfiguration.APPLEPAY_CONFIGURATION_KEY).FromJsonOrNull<MyWellIGatewayApplePayConfiguration>();
               
                string ovverrideDomain = GetAttributeValue(AttributeKey.OvverrideDomains);

                if (ovverrideDomain.IsNotNullOrWhiteSpace())
                {
                    lExternalRockAddress.Text = ovverrideDomain;
                }

                if (myWellGatewayApplePayConfiguration == null)
                {
                    ShowVerifyButton();
                }
                else
                {
                    ShowViewDetails();
                }
            }
        }

        /// <summary>
        /// Shows the view details.
        /// </summary>
        public void ShowViewDetails()
        {
           
            var myWellGatewayApplePayConfiguration = Rock.Web.SystemSettings.GetValue(org.mywell.MyWellGateway.SystemKey.MyWellGatewayConfiguration.APPLEPAY_CONFIGURATION_KEY).FromJsonOrNull<MyWellIGatewayApplePayConfiguration>();
            if (myWellGatewayApplePayConfiguration == null)
            {
                // shouldn't happen
                ShowVerifyButton();
            }
            else
            { 
                lMyWellApplePayId.Text = myWellGatewayApplePayConfiguration.ApplePayMerchantId;
                lBenevityId.Text = myWellGatewayApplePayConfiguration.BenevityId;

                // Check to make sure the domain is still verified. Otherwise we will need to verify it again
                var rockContext = new RockContext();
                var myWellFinancialGateway = new FinancialGatewayService(rockContext).Queryable().Where(x => x.EntityType.Name == "org.mywell.MyWellGateway.MyWellGateway").FirstOrDefault();
                MyWellGateway gateway = new MyWellGateway();
                string errorMessage = string.Empty;

                var response = gateway.GetApplePayVerifiedDomains(myWellFinancialGateway, out errorMessage);
                if (errorMessage.IsNotNullOrWhiteSpace())
                {
                    // if there is an error, that means there are no verified domains for this organization
                    ShowVerifyButton();
                    return;
                }

                String[] domains = lExternalRockAddress.Text.Split(',');

                foreach(string domain in domains)
                {
                    if (!response.DomainNames.Contains(domain))
                    {
                        ShowVerifyButton();
                        return;
                    }
                }

                if(domains.Length == 0)
                {
                    if (!response.DomainNames.Contains(lExternalRockAddress.Text))
                    {
                        ShowVerifyButton();
                        return;
                    }
                }

                pnlApplePayId.Visible = true;
                lDescription.Text = " <div class='mt-4 alert alert-success shadow-lg'>Your domain is verified and is configured for Apple Pay. Simply enable Apple Pay under the My Well Financial Gateway and start processing donations with Apple Pay.</div>";
                pnlVerifyMode.Visible = false;

            }


        }

        /// <summary>
        /// Shows the edit details.
        /// </summary>
        public void ShowVerifyButton()
        {

            // Initally the organization will not have an Apple Pay Merchant Id and will need to go through verifying their domain
            pnlApplePayId.Visible = false;

            // Reset the configuration when the domain needs to be verified.
            Rock.Web.SystemSettings.SetValue(org.mywell.MyWellGateway.SystemKey.MyWellGatewayConfiguration.APPLEPAY_CONFIGURATION_KEY, null);

            lDescription.Text = "<p>Before you start using Apple Pay, your organization needs to be added to Benevity's Database. Click <a href='https://help.mywell.org/how-to-add-your-organization-to-benevitys-database' _target='_blank'>here</a> to add your organization. Once the process is complete, click below to verify your domain with Apple and start using Apple Pay with the My Well Gateway.</p>";

            pnlVerifyMode.Visible = true;
        }

        /// <summary>
        /// Handles the Click event of the btnVerifyDomain control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void btnVerifyDomain_Click(object sender, EventArgs e)
        {
            pnErrorMessage.Visible = false;
            var myWellGatewayApplePayConfiguration = Rock.Web.SystemSettings.GetValue(org.mywell.MyWellGateway.SystemKey.MyWellGatewayConfiguration.APPLEPAY_CONFIGURATION_KEY).FromJsonOrNull<MyWellIGatewayApplePayConfiguration>();
            string errorMessage = string.Empty;
            var rockContext = new RockContext();
            var myWellFinancialGateway = new Rock.Model.FinancialGatewayService(rockContext).Queryable().Where(x => x.EntityType.Name == "org.mywell.MyWellGateway.MyWellGateway").FirstOrDefault();

            MyWellGateway gateway = new MyWellGateway();

            String[] domains = lExternalRockAddress.Text.Split(',');


            // rename the web.config.mywell to web.config
            // others plugins might use the .well-known directory and we don't want to interfier with other plugins
            string mywellWebConfig = System.Web.HttpContext.Current.Server.MapPath("~/.well-known/web.config.mywell");
            string renamedWebConfig = System.Web.HttpContext.Current.Server.MapPath("~/.well-known/web.config");
            System.IO.File.Move(mywellWebConfig, renamedWebConfig);

            if (myWellFinancialGateway != null)
            {
                string orgName = GlobalAttributesCache.Get().GetValue("OrganizationName");

                var applePayData = new CreateApplePayDomainData
                {
                    DomainNames = domains,
                    BenevityId = tbBenevityId.Text
                };

                myWellGatewayApplePayConfiguration = new MyWellIGatewayApplePayConfiguration();

                var response = gateway.RegisterApplePayDomains(myWellFinancialGateway, applePayData, out errorMessage);
                if(errorMessage.IsNotNullOrWhiteSpace())
                {
                    lErrorMessageTitle.Text = "<h3 class='mt-0'><i class='fa fa-exclamation-triangle mr-2 text-red-500'></i>Error Verifying Domain.</h3> <p>If you continue to have this issue please reach out to our support team.</p>";
                    lErrorBody.Text = errorMessage;
                    pnErrorMessage.Visible = true;

                    // rename the web.config back to orginial filename since we don't want to interfier with other plugins 
                    System.IO.File.Move(renamedWebConfig, mywellWebConfig);

                    return;
                }
                myWellGatewayApplePayConfiguration.ApplePayMerchantId = response.Id;
                myWellGatewayApplePayConfiguration.DomainName = response.DomainNames.FirstOrDefault();
                myWellGatewayApplePayConfiguration.BenevityId = tbBenevityId.Text;

                Rock.Web.SystemSettings.SetValue(org.mywell.MyWellGateway.SystemKey.MyWellGatewayConfiguration.APPLEPAY_CONFIGURATION_KEY, myWellGatewayApplePayConfiguration.ToJson());
                ShowViewDetails();

                // rename the web.config back to orginial filename since we don't want to interfier with other plugins 
                System.IO.File.Move(renamedWebConfig, mywellWebConfig);
            } 
        }
    }
}