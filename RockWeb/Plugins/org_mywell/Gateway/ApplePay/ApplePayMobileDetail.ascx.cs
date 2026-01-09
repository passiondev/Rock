using System;
using System.ComponentModel;
using System.Linq;
using System.Web.UI;
using System.Text;
using Rock;
using Rock.Data;
using Rock.Model;
using Rock.Web.Cache;
using org.mywell.MyWellGateway;
using org.mywell.MyWellGateway.Model;
using Rock.Attribute;

namespace RockWeb.Plugins.org_mywell.Gateway
{
    [DisplayName("My Well Gateway Apple Pay Mobile Detail")]
    [Category("My Well > Gateway")]
    [Description("My Well Gateway Apple Pay Mobile Details.")]
    [LinkedPage("List Page", order: 0)]

    public partial class ApplePayMobileDetail : Rock.Web.UI.RockBlock
    {
        #region Control Methods

        /// <summary>
        /// Raises the <see cref="E:System.Web.UI.Control.Init" /> event.
        /// </summary>
        /// <param name="e">An <see cref="T:System.EventArgs" /> object that contains the event data.</param>
        protected override void OnInit(EventArgs e)
        {
            base.OnInit(e);
            this.AddConfigurationUpdateTrigger(upnlContent);
            // this event gets fired after block settings are updated. it's nice to repaint the screen if these settings would alter it

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
                ScriptManager scriptManager = ScriptManager.GetCurrent(this.Page);
                scriptManager.RegisterPostBackControl(btnDownloadCSR);
                LoadActiveMyWellFinancialGateways();
            }

            imgMyWellLogo.ImageUrl = this.ResolveRockUrl("/Plugins/org_mywell/Assets/MyWellColor.svg");
        }

        #endregion

        #region Events

        /// <summary>
        /// Shows the verify edit details.
        /// </summary>
        public void LoadActiveMyWellFinancialGateways()
        {
            var rockContext = new RockContext();
            var myWellFinancialGatewayEntityId = new FinancialGatewayService(rockContext).Queryable().Where(x => x.EntityType.Name == "org.mywell.MyWellGateway.MyWellGateway").Select(x => x.EntityTypeId).FirstOrDefault();

            // we want to only show the My Well gatweay for the target gateway dropdown
            var financialTargetGatewayCount = fgFinancialGateway.Items.Count;

            // go through all the gateways and make sure we only show the My Well Gateway for the target gateway dopdown
            // note: an org can have multiple gateways as the My Well gateway so we want to show all of them
            for (int i = financialTargetGatewayCount - 1; i >= 0; i--)
            {
                var item = fgFinancialGateway.Items[i];
                var itemValue = item.Value.AsIntegerOrNull();
                var financialGateway = new FinancialGatewayService(rockContext).Queryable().Where(x => x.Id == itemValue).FirstOrDefault();

                if (financialGateway != null && financialGateway.EntityTypeId != myWellFinancialGatewayEntityId)
                {
                    fgFinancialGateway.Items.Remove(item);
                }
            }
        }

        /// <summary>
        /// Handles the Click event of the  btnCheckStatus control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void btnDownloadCSR_Click(object sender, EventArgs e)
        {

            // Get Common Name for certificate
            var organizationWebsite = GlobalAttributesCache.Get().GetValue("OrganizationWebsite");

            // Hardcode Organization Unit
            var organizationUnit = "HQ";

            // Set Organization Name
            var organizationName = GlobalAttributesCache.Get().GetValue("OrganizationName");

            // Set Location Information
            var organizationAddressLocationGuid = GlobalAttributesCache.Get().GetValue("OrganizationAddress").AsGuid();

            var orgCity = String.Empty;
            var orgCountry = String.Empty;
            var orgState = String.Empty;


            if (!organizationAddressLocationGuid.Equals(Guid.Empty))
            {
                var location = new LocationService(new RockContext()).Get(organizationAddressLocationGuid);
                if (location != null)
                {
                    orgCity = location.City;
                    orgCountry = location.Country;

                    // For the state we need the long state name (Arizona not AZ)
                    var systemStates = DefinedTypeCache.Get(Rock.SystemGuid.DefinedType.LOCATION_ADDRESS_STATE.AsGuid());
                    var addressState = systemStates.DefinedValues.Where(s => s.Value == location.State).FirstOrDefault();
                    orgState = addressState.Description;
                }
            }


            // Go through the values and ensure that none are invalid if so apply the MCS defaults
            if (
                organizationWebsite.IsNullOrWhiteSpace()
                || orgCountry.IsNullOrWhiteSpace()
                || orgCountry.Length > 2
                || organizationName.IsNullOrWhiteSpace()
                || orgCity.IsNullOrWhiteSpace()
                || orgState.IsNullOrWhiteSpace()
                || orgState.Length == 2
                )
            {
                return;
            }


            MyWellGateway gateway = new MyWellGateway();

            string errorMessage = string.Empty;

            var selectedFinacialGatewayId = fgFinancialGateway.SelectedValueAsInt();

            if (selectedFinacialGatewayId.HasValue)
            {
                var targetFinancialGateway = new FinancialGatewayService(new RockContext()).Get(selectedFinacialGatewayId.Value);

                if (targetFinancialGateway != null)
                {

                    OrganizationLocation organizationLocation = new OrganizationLocation
                    {
                        City = orgCity,
                        State = orgState,
                        Country = orgCountry,
                    };

                    ApplePayCSRRequest csrData = new ApplePayCSRRequest
                    {
                        CommonName = organizationWebsite,
                        OrganizationLocation = organizationLocation,
                        OrganizationName = organizationName,
                        OrganizationUnit = organizationUnit,

                    };

                    var response = gateway.GenerateApplePayCsrRequest(targetFinancialGateway, csrData, out errorMessage);
                    if (errorMessage.IsNotNullOrWhiteSpace())
                    {
                        lErrorMessageTitle.Text = "<h3 class='mt-0'><i class='fa fa-exclamation-triangle mr-2 text-red-500'></i>Error Generating CSR.</h3> <p>If you continue to have this issue please reach out to our support team.</p>";
                        lErrorBody.Text = errorMessage;
                        pnErrorMessage.Visible = true;
                        return;
                    }

                    pnlCSRDetails.Visible = false;
                    pnlCertificateUploadDetails.Visible = true;

                    Response.Clear();
                    Response.ContentType = "text/plain";
                    Response.AddHeader("Content-Disposition", string.Format(
                "attachment; filename={0}.certSigningRequest", "mywell"));
                    Response.Write(response.Csr);
                    Response.End();

                }


            }


        }

        /// <summary>
        /// Handles the Click event of the  btnCheckStatus control.
        /// </summary>
        /// <param name="sender">The source of the event.</param>
        /// <param name="e">The <see cref="EventArgs"/> instance containing the event data.</param>
        protected void btnUploadCertificate_Click(object sender, EventArgs e)
        {
            // Check to make sure the domain is still verified. Otherwise we will need to verify it again
            MyWellGateway gateway = new MyWellGateway();
            string errorMessage = string.Empty;

            var selectedFinacialGatewayId = fgFinancialGateway.SelectedValueAsInt();

            if (selectedFinacialGatewayId.HasValue)
            {
                using (var rockContext = new RockContext())
                {
                    var targetFinancialGateway = new FinancialGatewayService(rockContext).Get(selectedFinacialGatewayId.Value);

                    if (targetFinancialGateway != null)
                    {
                        // Get the file imported and make sure its a csv
                        var certificate = this.Request.MapPath(fuUploader.UploadedContentFilePath);

                        BinaryFileService binaryFileService = new BinaryFileService(rockContext);
                        BinaryFile certifiacteBinaryFile = binaryFileService.Get(fuUploader.BinaryFileId.Value);

                        if (certifiacteBinaryFile != null && certifiacteBinaryFile.FileName.EndsWith(".cer"))
                        {
                            var data = certifiacteBinaryFile.ContentStream.ReadBytesToEnd();

                            var pemfile = String.Empty;
                            string merchantId = string.Empty;

                            using (var cert = new System.Security.Cryptography.X509Certificates.X509Certificate2(data))
                            {
                                string[] subjectArray = cert.Subject.Split(',');
                                string[] nameParts = new string[] { };
                                string CN = string.Empty;


                                // we want to only take the common name in the subject to extract the merchant id
                                foreach (string item in subjectArray)
                                {
                                    string[] oneItem = item.Split('=');
                                    // Split the Subject CN information
                                    if (oneItem[0].Trim() == "CN")
                                    {
                                        CN = oneItem[1];

                                    }
                                }

                                // extract the merchant id
                                if (CN.IsNotNullOrWhiteSpace())
                                {
                                    string[] merchantItems = CN.Split(':');
                                    // format of CN should be Apple Pay Payment Processing:merchant.io.mywell.dev
                                    if (merchantItems.Length > 1)
                                    {
                                        merchantId = merchantItems[1];
                                    }
                                }

                                if (merchantId.IsNullOrWhiteSpace())
                                {
                                    //error
                                    return;
                                }


                                StringBuilder builder = new StringBuilder();
                                builder.AppendLine("-----BEGIN CERTIFICATE-----");
                                builder.AppendLine(Convert.ToBase64String(cert.RawData, Base64FormattingOptions.InsertLineBreaks));
                                builder.Append("-----END CERTIFICATE-----");
                                pemfile = builder.ToString();
                            }

                            ApplePayCertificate appleCertificate = new ApplePayCertificate
                            {
                                Certificate = pemfile,
                                MerchantId = merchantId,
                            };

                            var response = gateway.UploadApplePayCertificateRequest(targetFinancialGateway, appleCertificate, out errorMessage);
                            if (errorMessage.IsNotNullOrWhiteSpace())
                            {
                                lErrorMessageTitle.Text = "<h3 class='mt-0'><i class='fa fa-exclamation-triangle mr-2 text-red-500'></i>Error Uploading Certificate.</h3> <p>If you continue to have this issue please reach out to our support team.</p>";
                                lErrorBody.Text = errorMessage;
                                pnErrorMessage.Visible = true;
                                return;
                            }


                            // check if the the gateway already has a certificate
                            var appleCertiticateService = new MyWellGatewayAppleCertificateService(rockContext);
                            var existingCertificate = appleCertiticateService.Queryable().Where(c => c.FinancialGatewayId == selectedFinacialGatewayId.Value).FirstOrDefault();

                            if (existingCertificate != null)
                            {

                                existingCertificate.MerchantId = response.MerchantId;
                                existingCertificate.CertificateId = response.CertificateId;
                                existingCertificate.ValidFrom = response.ValidFrom;
                                existingCertificate.ValidTo = response.ValidTo;
                                rockContext.SaveChanges();
                            }
                            else
                            {
                                var newCertificate = new MyWellGatewayAppleCertificate
                                {
                                    MerchantId = response.MerchantId,
                                    CertificateId = response.CertificateId,
                                    ValidFrom = response.ValidFrom,
                                    ValidTo = response.ValidTo,
                                    FinancialGateway = targetFinancialGateway,
                                };

                                appleCertiticateService.Add(newCertificate);
                                rockContext.SaveChanges();
                            }

                            NavigateToLinkedPage("ListPage");
                        }
                    }
                }
            }
        }

    }
    #endregion
}



