System.register(['tslib', 'vue', '@Obsidian/Controls/loadingIndicator.obs', '@Obsidian/Core/Controls/financialGateway', '@Obsidian/Enums/Controls/gatewayEmitStrings', './googlePay.js', './applePay.js'], (function (exports) {
  'use strict';
  var __awaiter, defineComponent, ref, computed, onMounted, LoadingIndicator, onSubmitPayment, GatewayEmitStrings, GooglePay, ApplePay;
  return {
    setters: [function (module) {
      __awaiter = module.__awaiter;
    }, function (module) {
      defineComponent = module.defineComponent;
      ref = module.ref;
      computed = module.computed;
      onMounted = module.onMounted;
    }, function (module) {
      LoadingIndicator = module["default"];
    }, function (module) {
      onSubmitPayment = module.onSubmitPayment;
    }, function (module) {
      GatewayEmitStrings = module.GatewayEmitStrings;
    }, function (module) {
      GooglePay = module["default"];
    }, function (module) {
      ApplePay = module["default"];
    }],
    execute: (function () {

      var myWellGatewayTokenizer = exports('default', defineComponent({
          name: "MyWellPlatformGatewayControl",
          components: {
              LoadingIndicator,
              GooglePay,
              ApplePay,
          },
          props: {
              settings: {
                  type: Object,
                  required: true,
              },
              submit: {
                  type: Boolean,
                  required: true,
              },
          },
          setup(props, { emit }) {
              const loading = ref(true);
              const creditCardTokenizer = ref(null);
              const achTokenizer = ref(null);
              const creditCardContainer = ref();
              const achContainer = ref();
              let achErrors = {};
              let creditCardErrors = {};
              const requireCVV = props.settings.requireCVV;
              const verifyACH = props.settings.verifyACH;
              const educationalText = props.settings.educationalText;
              const appleMerchantId = props.settings.applePayMerchantId;
              const googlePayToken = props.settings.googlePayToken;
              const googleMerchantId = props.settings.googleMerchantId;
              const domainName = props.settings.domainName;
              const applePayCertificateId = props.settings.applePayCertificateId;
              const googlePayContainer = ref();
              const applePayContainer = ref();
              const gatewayUrl = props.settings.gatewayUrl;
              const publicApiKey = props.settings.publicApiKey;
              const apiUrl = props.settings.apiUrl;
              const myWellPublicApiKey = props.settings.myWellPublicApiKey;
              const financialGatewayId = props.settings.financialGatewayId;
              const orgName = props.settings.orgName;
              const hasCreditCardPaymentType = computed(() => {
                  var _a, _b;
                  return ((_b = (_a = props.settings.enabledPaymentTypes) === null || _a === void 0 ? void 0 : _a.includes(0)) !== null && _b !== void 0 ? _b : false);
              });
              const hasBankAccountPaymentType = computed(() => {
                  var _a, _b;
                  return ((_b = (_a = props.settings.enabledPaymentTypes) === null || _a === void 0 ? void 0 : _a.includes(1)) !== null && _b !== void 0 ? _b : false);
              });
              const hasApplePayPaymentType = computed(() => {
                  var _a;
                  if (window.ApplePaySession &&
                      window.ApplePaySession.canMakePayments &&
                      ((_a = props.settings.enabledPaymentTypes) === null || _a === void 0 ? void 0 : _a.includes(2)) &&
                      appleMerchantId) {
                      return true;
                  }
                  return false;
              });
              const hasGooglePayPaymentType = computed(() => {
                  var _a, _b;
                  return ((_b = (_a = props.settings.enabledPaymentTypes) === null || _a === void 0 ? void 0 : _a.includes(3)) !== null && _b !== void 0 ? _b : false);
              });
              const hasMultiplePaymentTypes = computed(() => {
                  return props.settings.enabledPaymentTypes &&
                      props.settings.enabledPaymentTypes.length > 1
                      ? true
                      : false;
              });
              let activePaymentType = ref();
              if (props.settings.enabledPaymentTypes != null &&
                  props.settings.enabledPaymentTypes.length > 0) {
                  if (hasMultiplePaymentTypes.value && hasBankAccountPaymentType.value) {
                      activePaymentType.value = props.settings.enabledPaymentTypes[1];
                  }
                  else {
                      activePaymentType.value = props.settings.enabledPaymentTypes[0];
                  }
              }
              const isCreditCardPaymentTypeActive = computed(() => {
                  return activePaymentType.value === 0;
              });
              const isBankAccountPaymentTypeActive = computed(() => {
                  return activePaymentType.value === 1;
              });
              const isApplePayPaymentTypeActive = computed(() => {
                  return activePaymentType.value === 2;
              });
              const isGooglePayPaymentTypeActive = computed(() => {
                  return activePaymentType.value === 3;
              });
              const creditCardButtonClasses = computed(() => {
                  return isCreditCardPaymentTypeActive.value
                      ? ["btn", "btn-primary", "active"]
                      : ["btn", "btn-default"];
              });
              const bankAccountButtonClasses = computed(() => {
                  return isBankAccountPaymentTypeActive.value
                      ? ["btn", "btn-primary", "active"]
                      : ["btn", "btn-default"];
              });
              const applePayButtonClasses = computed(() => {
                  return isApplePayPaymentTypeActive.value
                      ? ["btn", "btn-primary", "active", "bg-black"]
                      : ["btn", "btn-default"];
              });
              const googlePayButtonClasses = computed(() => {
                  return isGooglePayPaymentTypeActive.value
                      ? ["btn", "btn-primary", "active", "bg-black"]
                      : ["btn", "btn-default"];
              });
              const loadingButtonClasses = computed(() => {
                  return loading.value ? ["disabled"] : [""];
              });
              const applePayIconClasses = computed(() => {
                  return isApplePayPaymentTypeActive.value
                      ? ["border-white"]
                      : ["border-black"];
              });
              const googlePayIconClasses = computed(() => {
                  return isGooglePayPaymentTypeActive.value
                      ? ["border-white"]
                      : ["border-black"];
              });
              const activateCreditCard = () => {
                  activePaymentType.value = 0;
                  emit("validation", creditCardErrors);
              };
              const activateBankAccount = () => {
                  activePaymentType.value = 1;
                  emit("validation", achErrors);
              };
              const activateApplePay = () => {
                  activePaymentType.value = 2;
                  emit("validation", achErrors);
              };
              const activateGooglePay = () => {
                  activePaymentType.value = 3;
                  emit("validation", achErrors);
              };
              const gatewayPaymentContainer = {
                  borderRadius: "16px",
                  boxShadow: "rgb(33 33 33 / 13%) 0px 1px 16px",
              };
              const tokenizerSettings = () => {
                  return {
                      onLoad: () => {
                          loading.value = false;
                      },
                      apikey: publicApiKey,
                      url: props.settings.gatewayUrl,
                      container: creditCardContainer.value,
                      submission: (resp) => {
                          handleResponse(resp);
                      },
                      settings: {
                          payment: {
                              showTitle: true,
                              types: ["card"],
                              ach: {
                                  sec_code: "web",
                                  verifyAccountRouting: verifyACH,
                              },
                              card: {
                                  requireCVV: requireCVV,
                              },
                          },
                          billing: {
                              show: true,
                              showTitle: true,
                          },
                          styles: {
                              body: {
                                  color: "rgb(51, 51, 51)",
                                  "font-family": "'Helvetica Neue', Helvetica, Arial, sans-serif",
                              },
                              "#app": {
                                  padding: "5px 15px",
                              },
                              "input,select": {
                                  color: "rgb(85, 85, 85)",
                                  "border-radius": "4px",
                                  "background-color": "rgb(255, 255, 255)",
                                  border: "1px solid rgb(204, 204, 204)",
                                  "box-shadow": "rgba(0, 0, 0, 0.075) 0px 1px 1px 0px inset",
                                  padding: "6px 12px",
                                  "font-size": "14px",
                                  height: "34px",
                                  "font-family": "OpenSans, 'Helvetica Neue', Helvetica, Arial, sans-serif",
                              },
                              "input:focus,select:focus": {
                                  border: "1px solid #66afe9",
                                  "box-shadow": "0 0 0 3px rgba(102,175,233,0.6)",
                              },
                              select: {
                                  padding: "6px 4px",
                              },
                              "input[type=number]::-webkit-inner-spin-button,input[type=number]::-webkit-outer-spin-button": {
                                  "-webkit-appearance": "none",
                                  margin: "0",
                              },
                              ".title": {
                                  padding: "10px 0 20px !important",
                              },
                              ".billing .fieldset": {
                                  padding: "0 0 15px !important",
                              },
                              ".billing .fieldsetrow": {
                                  padding: "0 0 15px !important",
                                  "column-gap": "5px",
                              },
                              ".fieldsetrow .fieldset": {
                                  "padding-bottom": "5px !important",
                              },
                              ".ach .fieldsetrow": {
                                  "flex-wrap": "wrap-reverse",
                                  "flex-direction": "row-reverse",
                                  "justify-content": "center",
                                  width: "auto",
                              },
                              ".fieldsetgroup": {
                                  flex: "1",
                              },
                              ".ach .account": {
                                  padding: "0 5px 0 5px !important",
                              },
                          },
                      },
                  };
              };
              onMounted(() => __awaiter(this, void 0, void 0, function* () {
                  const globalVarName = "Tokenizer";
                  emit("validation", "");
                  if (!window[globalVarName]) {
                      const script = document.createElement("script");
                      script.type = "text/javascript";
                      script.src = `${props.settings.gatewayUrl}/tokenizer/tokenizer.js`;
                      const walletjs = document.createElement("script");
                      walletjs.type = "text/javascript";
                      walletjs.src = `${props.settings.gatewayUrl}/walletjs/walletjs.js`;
                      const gatewayCss = document.createElement("link");
                      gatewayCss.type = "text/css";
                      gatewayCss.rel = "stylesheet";
                      gatewayCss.href = "/Plugins/org_mywell/Gateway/Styles/gateway.css";
                      const googlepayjs = document.createElement("script");
                      googlepayjs.type = "text/javascript";
                      googlepayjs.src = `https://pay.google.com/gp/p/js/pay.js`;
                      document
                          .getElementsByTagName("head")[0]
                          .appendChild(script)
                          .appendChild(walletjs)
                          .appendChild(gatewayCss)
                          .appendChild(googlepayjs);
                      const sleep = () => new Promise((resolve) => setTimeout(resolve, 20));
                      while (!window[globalVarName]) {
                          yield sleep();
                      }
                  }
                  if (hasCreditCardPaymentType.value) {
                      let creditCardSettings = tokenizerSettings();
                      creditCardSettings.container = creditCardContainer.value;
                      creditCardSettings.settings.payment.types = ["card"];
                      creditCardTokenizer.value = new window[globalVarName](creditCardSettings);
                      creditCardTokenizer.value.create();
                  }
                  if (hasBankAccountPaymentType.value) {
                      let achSettings = tokenizerSettings();
                      achSettings.container = achContainer.value;
                      achSettings.settings.payment.types = ["ach"];
                      achTokenizer.value = new window[globalVarName](achSettings);
                      achTokenizer.value.create();
                  }
              }));
              onSubmitPayment(() => {
                  if (hasBankAccountPaymentType.value || hasApplePayPaymentType.value) {
                      loading.value = true;
                  }
                  if (isBankAccountPaymentTypeActive.value && achTokenizer.value != null) {
                      achTokenizer.value.submit();
                  }
                  if (isCreditCardPaymentTypeActive.value &&
                      creditCardTokenizer.value != null) {
                      creditCardTokenizer.value.submit();
                  }
                  if (isGooglePayPaymentTypeActive.value &&
                      googlePayContainer.value != null) {
                      googlePayContainer.value.onGooglePayClick();
                  }
                  if (isApplePayPaymentTypeActive.value &&
                      applePayContainer.value != null) {
                      applePayContainer.value.onApplePayClick();
                  }
              });
              const handleResponse = function (response) {
                  var _a;
                  if (!(response === null || response === void 0 ? void 0 : response.status) || response.status === "error") {
                      loading.value = false;
                      const errorResponse = response || null;
                      emit("error", (errorResponse === null || errorResponse === void 0 ? void 0 : errorResponse.message) ||
                          "There was a problem with the details below. Please make sure the address and payment method are correct and try again.");
                      console.error("MyWell response was errored:", JSON.stringify(response));
                      return;
                  }
                  if (response.status === "validation") {
                      loading.value = false;
                      const validationResponse = response || null;
                      if (!((_a = validationResponse === null || validationResponse === void 0 ? void 0 : validationResponse.invalid) === null || _a === void 0 ? void 0 : _a.length)) {
                          emit("error", "There was a validation issue, but the invalid field was not specified.");
                          console.error("MyWell response was errored:", JSON.stringify(response));
                          return;
                      }
                      let achErrors = [];
                      let creditCardErrors = [];
                      isCreditCardPaymentTypeActive.value
                          ? (creditCardErrors = [])
                          : (achErrors = []);
                      for (const myWellField of validationResponse.invalid) {
                          switch (myWellField) {
                              case "cc":
                                  creditCardErrors.push({
                                      name: "Credit Card",
                                      text: "is invalid",
                                  });
                                  break;
                              case "exp":
                                  creditCardErrors.push({
                                      name: "Expiration Date",
                                      text: "is invalid",
                                  });
                                  break;
                              case "cvv":
                                  creditCardErrors.push({ name: "CVV", text: "is invalid" });
                                  break;
                              case "account":
                                  achErrors.push({ name: "Account Number", text: "is invalid" });
                                  break;
                              case "routing":
                                  achErrors.push({ name: "Routing Number", text: "is invalid" });
                                  break;
                              default:
                                  console.error("Unknown MyWell validation field", myWellField);
                                  break;
                          }
                      }
                      if (isBankAccountPaymentTypeActive.value) {
                          if (achErrors == []) {
                              emit("error", "There was a validation issue, but the invalid field could not be inferred.");
                              console.error("MyWell response contained unexpected values:", JSON.stringify(response));
                              return;
                          }
                          emit("validation", achErrors);
                          return;
                      }
                      if (isCreditCardPaymentTypeActive.value) {
                          if (creditCardErrors == []) {
                              emit("error", "There was a validation issue, but the invalid field could not be inferred.");
                              console.error("MyWell response contained unexpected values:", JSON.stringify(response));
                              return;
                          }
                          emit("validation", creditCardErrors);
                          return;
                      }
                  }
                  if (response.status === "success") {
                      const fluidPayResponse = response || null;
                      if (!(fluidPayResponse === null || fluidPayResponse === void 0 ? void 0 : fluidPayResponse.token)) {
                          loading.value = false;
                          emit("error", "There was a problem with the details below. Please make sure the address and payment method are correct and try again.");
                          console.error("MyWell response does not have the expected token:", JSON.stringify(response));
                          return;
                      }
                      console.log("response is " + JSON.stringify(fluidPayResponse, null, 2));
                      emit("success", JSON.stringify(fluidPayResponse));
                      if (hasBankAccountPaymentType.value || hasApplePayPaymentType.value) {
                          activePaymentType.value = 17;
                      }
                      return;
                  }
                  loading.value = false;
                  emit("error", "There was an unexpected problem communicating with the gateway.");
                  console.error("MyWell response has invalid status:", JSON.stringify(response));
              };
              const onError = (message) => {
                  emit(GatewayEmitStrings.Error, message);
              };
              const onSuccess = (token) => {
                  emit(GatewayEmitStrings.Success, token);
              };
              const onLoading = (loadingStatus) => {
                  loading.value = loadingStatus;
              };
              return {
                  hasMultiplePaymentTypes,
                  activateCreditCard,
                  activateBankAccount,
                  activateApplePay,
                  isCreditCardPaymentTypeActive,
                  isBankAccountPaymentTypeActive,
                  isGooglePayPaymentTypeActive,
                  isApplePayPaymentTypeActive,
                  creditCardButtonClasses,
                  bankAccountButtonClasses,
                  applePayButtonClasses,
                  googlePayButtonClasses,
                  googlePayIconClasses,
                  applePayIconClasses,
                  loadingButtonClasses,
                  hasBankAccountPaymentType,
                  hasCreditCardPaymentType,
                  hasApplePayPaymentType,
                  hasGooglePayPaymentType,
                  creditCardContainer,
                  achContainer,
                  publicApiKey,
                  educationalText,
                  financialGatewayId,
                  orgName,
                  apiUrl,
                  myWellPublicApiKey,
                  loading,
                  gatewayPaymentContainer,
                  activateGooglePay,
                  googlePayContainer,
                  applePayContainer,
                  applePayCertificateId,
                  googleMerchantId,
                  gatewayUrl,
                  appleMerchantId,
                  googlePayToken,
                  domainName,
                  onError,
                  onSuccess,
                  onLoading,
              };
          },
          template: `
<div class="p-3">
  <div :style="gatewayPaymentContainer" class="well mb-0 pb-5 ml-auto mr-auto">
      <div v-if="hasApplePayPaymentType || hasBankAccountPaymentType || hasGooglePayPaymentType " class="gateway-type-selector" role="group">
          <h4 class="btn-group btn-group-justified mb-5 mt-4" style="text-align: center;">Select Payment Method</h4>
          <div class="gateway-type-selector w-100 d-flex border rounded-pill border-gray-300 p-1 mt-4 bg-white">
              <a v-if="hasBankAccountPaymentType" class="js-payment-ach payment-ach rounded-pill d-flex w-100 justify-content-center align-items-center m-0" :class="bankAccountButtonClasses,loadingButtonClasses" @click.prevent="activateBankAccount" style="border:none">
                  <i class='fas fa-university p-2 pr-3 fa-2x'></i><p class='d-flex h-100 align-items-center m-0'>Bank Account</p>
              </a>
              <a class="js-payment-ach payment-ach rounded-pill d-flex w-100 justify-content-center align-items-center m-0" :class="creditCardButtonClasses,loadingButtonClasses" @click.prevent="activateCreditCard" style="border:none">
                  <i class='fas fa-credit-card p-2 pr-3 fa-2x'></i><p class='d-flex h-100 align-items-center m-0'>Card</p>
              </a>
              <ApplePay
                  v-if="hasApplePayPaymentType" 
                  ref="applePayContainer"
                  :applePayButtonClasses="applePayButtonClasses"
                  :activateApplePay="activateApplePay"
                  :applePayIconClasses="applePayIconClasses"
                  :loadingButtonClasses="loadingButtonClasses"
                  :handleResponse="handleResponse"
                  :applePayCertificateId="applePayCertificateId"
                  :gatewayUrl="gatewayUrl"
                  :appleMerchantId="appleMerchantId"
                  :domainName="domainName"
                  @success="onSuccess"
                  @error="onError"
                  @loading="onLoading" />

             <GooglePay
                  v-if="hasGooglePayPaymentType" 
                  ref="googlePayContainer"
                  :publicApiKey="publicApiKey"
                  :apiUrl="apiUrl"
                  :financialGatewayId="financialGatewayId"
                  :orgName ="orgName"
                  :myWellPublicApiKey="myWellPublicApiKey"
                  :googleMerchantId="googleMerchantId"
                  :domainName="domainName"
                  :googlePayButtonClasses="googlePayButtonClasses"
                  :activateGooglePay="activateGooglePay"
                  :googlePayIconClasses="googlePayIconClasses"
                  :loadingButtonClasses="loadingButtonClasses"
                  :googlePayToken="googlePayToken"
                  @success="onSuccess"
                  @error="onError"
                  @loading="onLoading" />
          </div>
          <div v-if="!loading && hasBankAccountPaymentType && educationalText">
              <div v-if="isCreditCardPaymentTypeActive || isApplePayPaymentTypeActive ||  isGooglePayPaymentTypeActive">
                  <p style="text-align:center; font-size: 15px;" class="well bg-white btn-group btn-group-justified mb-4 mt-5"><i class="fa fa-info-circle mr-2"/><strong>Did you know?</strong> Using a Bank Account is the most cost effective way to complete a transaction?</p>
              </div>
              <div v-if="isBankAccountPaymentTypeActive">
                  <p style="text-align:center; font-size: 15px;" class="btn-group btn-group-justified mb-4 mt-5"><i class="fa fa-info-circle mr-2"/><strong>Nice job!</strong> Using a Bank Account means we pay the lowest fees to process your transaction!</p>
              </div>
          </div>
      </div>
      <div v-if="loading" class="text-center pt-5">
          <LoadingIndicator />
      </div>
      <div>
          <div ref="creditCardContainer" v-if="hasCreditCardPaymentType" v-show="isCreditCardPaymentTypeActive" style="min-height: 49px;"></div>
          <div ref="achContainer" v-if="hasBankAccountPaymentType" v-show="isBankAccountPaymentTypeActive" style="min-height: 49px;"></div>
      </div>
  </div>
</div>`,
      }));

    })
  };
}));
