System.register(['vue'], (function (exports) {
    'use strict';
    var defineComponent, ref, computed;
    return {
        setters: [function (module) {
            defineComponent = module.defineComponent;
            ref = module.ref;
            computed = module.computed;
        }],
        execute: (function () {

            var GooglePay = exports('default', defineComponent({
                name: "GooglePay",
                props: {
                    googlePayButtonClasses: {
                        type: [String],
                        required: true,
                    },
                    googlePayIconClasses: {
                        type: [String],
                        required: true,
                    },
                    loadingButtonClasses: {
                        type: [String],
                        required: true,
                    },
                    activateGooglePay: {
                        type: Function,
                        required: true,
                    },
                    handleResponse: {
                        type: Function,
                        required: true,
                    },
                    googleMerchantId: {
                        type: String,
                        required: true,
                    },
                    publicApiKey: {
                        type: String,
                        required: true,
                    },
                    domainName: {
                        type: String,
                        required: true,
                    },
                    myWellPublicApiKey: {
                        type: String,
                        required: true,
                    },
                    financialGatewayId: {
                        type: String,
                        required: true,
                    },
                    apiUrl: {
                        type: String,
                        required: true,
                    },
                    orgName: {
                        type: String,
                        required: true,
                    },
                    googlePayToken: {
                        type: String,
                        required: true,
                    },
                },
                setup(props, { emit }) {
                    const googlePayContainer = ref();
                    const activateGooglePay = () => {
                        return props.activateGooglePay();
                    };
                    const googlePayIconClasses = computed(() => {
                        return props.googlePayIconClasses;
                    });
                    const googlePayButtonClasses = computed(() => {
                        return props.googlePayButtonClasses;
                    });
                    const loadingButtonClasses = computed(() => {
                        return props.loadingButtonClasses;
                    });
                    const jquery = window["$"];
                    const paymentAmountText = jquery('.registrationentry-payment div:contains("Payment Amount")').text();
                    var totalAmount = parseFloat(paymentAmountText.replace(/[^.0-9]/g, ""));
                    const onGooglePayClick = () => {
                        const googlePaySettings = {
                            container: googlePayContainer.value,
                            merchantName: props.orgName,
                            merchantId: props.googleMerchantId,
                            gatewayMerchantId: props.publicApiKey,
                            merchantOrigin: props.domainName,
                            authJwt: props.googlePayToken,
                            allowedCardNetworks: [
                                "AMEX",
                                "DISCOVER",
                                "INTERAC",
                                "JCB",
                                "MASTERCARD",
                                "VISA",
                            ],
                            allowedCardAuthMethods: ["PAN_ONLY"],
                            transactionInfo: {
                                countryCode: "US",
                                currencyCode: "USD",
                                totalPrice: totalAmount.toString(),
                            },
                            billingAddressRequired: true,
                            billingAddressParameters: {
                                format: "FULL",
                            },
                            onGooglePaymentButtonClicked: (paymentDataRequest) => {
                                paymentDataRequest
                                    .then((paymentData) => {
                                    handleResponse(paymentData);
                                    paymentData.paymentMethodData.tokenizationData.token;
                                })
                                    .catch((err) => {
                                    console.log("Error: " + JSON.stringify(err, null, 2));
                                    handleResponse(err);
                                });
                            },
                        };
                        const gp = new window["walletjs"]["GooglePay"](googlePaySettings);
                        gp.onGooglePaymentButtonClicked();
                    };
                    const handleResponse = function (response) {
                        var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k;
                        if ((response === null || response === void 0 ? void 0 : response.statusCode) === "CANCELED") {
                            emit("loading", false);
                            emit("error", "");
                            console.error("MyWell response was errored:", JSON.stringify(response));
                            return;
                        }
                        const fluidPayResponse = response || null;
                        if (!((_b = (_a = fluidPayResponse === null || fluidPayResponse === void 0 ? void 0 : fluidPayResponse.paymentMethodData) === null || _a === void 0 ? void 0 : _a.tokenizationData) === null || _b === void 0 ? void 0 : _b.token)) {
                            emit("error", "There was an unexpected problem with the google pay payment method.");
                            console.error("MyWell response does not have the expected token:", JSON.stringify(response));
                            return;
                        }
                        const { address1, address2, locality, administrativeArea, postalCode, countryCode, } = (_d = (_c = fluidPayResponse.paymentMethodData) === null || _c === void 0 ? void 0 : _c.info) === null || _d === void 0 ? void 0 : _d.billingAddress;
                        const billingAddress = {
                            address: `${address1}${address2 && " " + address2}`,
                            city: locality,
                            state: administrativeArea,
                            zip: postalCode,
                            country: countryCode,
                        };
                        const successfulResponse = {
                            status: "success",
                            currencyType: 3,
                            displayName: `${(_f = (_e = fluidPayResponse.paymentMethodData) === null || _e === void 0 ? void 0 : _e.info) === null || _f === void 0 ? void 0 : _f.cardNetwork} ${(_h = (_g = fluidPayResponse.paymentMethodData) === null || _g === void 0 ? void 0 : _g.info) === null || _h === void 0 ? void 0 : _h.cardDetails}`,
                            token: (_k = (_j = fluidPayResponse.paymentMethodData) === null || _j === void 0 ? void 0 : _j.tokenizationData) === null || _k === void 0 ? void 0 : _k.token,
                            billing: billingAddress,
                        };
                        emit("success", JSON.stringify(successfulResponse));
                        return;
                    };
                    return {
                        googlePayContainer,
                        googlePayButtonClasses,
                        activateGooglePay,
                        onGooglePayClick,
                        googlePayIconClasses,
                        loadingButtonClasses,
                    };
                },
                template: `
<div ref="googlePayContainer" style="display:none"></div>
<a class="js-payment-googlepay payment-googlepay rounded-pill d-flex w-100 justify-content-center align-items-center m-0" :class="googlePayButtonClasses,loadingButtonClasses" @click.prevent="activateGooglePay" style="border:none">
    <div class="d-flex align-items-center">
        <svg version='1.1' id='G_Pay_Acceptance_Mark' xmlns='http://www.w3.org/2000/svg' xmlns:xlink='http://www.w3.org/1999/xlink' x='0px' y='0px' viewBox='0 0 1094 742' enable-background='new 0 0 1094 742' xml:space='preserve' style='
                    width: 90px;
                '>
                <path id='Base_1_' fill='#FFFFFF' d='M722.7,170h-352c-110,0-200,90-200,200l0,0c0,110,90,200,200,200h352c110,0,200-90,200-200l0,0
	                C922.7,260,832.7,170,722.7,170z'></path>
                <path id='Outline' fill='#3C4043' d='M722.7,186.2c24.7,0,48.7,4.9,71.3,14.5c21.9,9.3,41.5,22.6,58.5,39.5
	                c16.9,16.9,30.2,36.6,39.5,58.5c9.6,22.6,14.5,46.6,14.5,71.3s-4.9,48.7-14.5,71.3c-9.3,21.9-22.6,41.5-39.5,58.5
	                c-16.9,16.9-36.6,30.2-58.5,39.5c-22.6,9.6-46.6,14.5-71.3,14.5h-352c-24.7,0-48.7-4.9-71.3-14.5c-21.9-9.3-41.5-22.6-58.5-39.5
	                c-16.9-16.9-30.2-36.6-39.5-58.5c-9.6-22.6-14.5-46.6-14.5-71.3s4.9-48.7,14.5-71.3c9.3-21.9,22.6-41.5,39.5-58.5
	                c16.9-16.9,36.6-30.2,58.5-39.5c22.6-9.6,46.6-14.5,71.3-14.5L722.7,186.2 M722.7,170h-352c-110,0-200,90-200,200l0,0
	                c0,110,90,200,200,200h352c110,0,200-90,200-200l0,0C922.7,260,832.7,170,722.7,170L722.7,170z'></path>
                <g id='G_Pay_Lockup_1_'>
	                <g id='Pay_Typeface_3_'>
		                <path id='Letter_p_3_' fill='#3C4043' d='M529.3,384.2v60.5h-19.2V295.3H561c12.9,0,23.9,4.3,32.9,12.9
			                c9.2,8.6,13.8,19.1,13.8,31.5c0,12.7-4.6,23.2-13.8,31.7c-8.9,8.5-19.9,12.7-32.9,12.7h-31.7V384.2z M529.3,313.7v52.1h32.1
			                c7.6,0,14-2.6,19-7.7c5.1-5.1,7.7-11.3,7.7-18.3c0-6.9-2.6-13-7.7-18.1c-5-5.3-11.3-7.9-19-7.9h-32.1V313.7z'></path>
		                <path id='Letter_a_3_' fill='#3C4043' d='M657.9,339.1c14.2,0,25.4,3.8,33.6,11.4c8.2,7.6,12.3,18,12.3,31.2v63h-18.3v-14.2h-0.8
			                c-7.9,11.7-18.5,17.5-31.7,17.5c-11.3,0-20.7-3.3-28.3-10s-11.4-15-11.4-25c0-10.6,4-19,12-25.2c8-6.3,18.7-9.4,32-9.4
			                c11.4,0,20.8,2.1,28.1,6.3v-4.4c0-6.7-2.6-12.3-7.9-17c-5.3-4.7-11.5-7-18.6-7c-10.7,0-19.2,4.5-25.4,13.6l-16.9-10.6
			                C625.9,345.8,639.7,339.1,657.9,339.1z M633.1,413.3c0,5,2.1,9.2,6.4,12.5c4.2,3.3,9.2,5,14.9,5c8.1,0,15.3-3,21.6-9
			                s9.5-13,9.5-21.1c-6-4.7-14.3-7.1-25-7.1c-7.8,0-14.3,1.9-19.5,5.6C635.7,403.1,633.1,407.8,633.1,413.3z'></path>
		                <path id='Letter_y_3_' fill='#3C4043' d='M808.2,342.4l-64,147.2h-19.8l23.8-51.5L706,342.4h20.9l30.4,73.4h0.4l29.6-73.4H808.2z'></path>
	                </g>
	                <g id='G_Mark_1_'>
		                <path id='Blue_500' fill='#4285F4' d='M452.93,372c0-6.26-0.56-12.25-1.6-18.01h-80.48v33L417.2,387
			                c-1.88,10.98-7.93,20.34-17.2,26.58v21.41h27.59C443.7,420.08,452.93,398.04,452.93,372z'></path>
		                <path id='Green_500_1_' fill='#34A853' d='M400.01,413.58c-7.68,5.18-17.57,8.21-29.14,8.21c-22.35,0-41.31-15.06-48.1-35.36
			                h-28.46v22.08c14.1,27.98,43.08,47.18,76.56,47.18c23.14,0,42.58-7.61,56.73-20.71L400.01,413.58z'></path>
		                <path id='Yellow_500_1_' fill='#FABB05' d='M320.09,370.05c0-5.7,0.95-11.21,2.68-16.39v-22.08h-28.46
			                c-5.83,11.57-9.11,24.63-9.11,38.47s3.29,26.9,9.11,38.47l28.46-22.08C321.04,381.26,320.09,375.75,320.09,370.05z'></path>
		                <path id='Red_500' fill='#E94235' d='M370.87,318.3c12.63,0,23.94,4.35,32.87,12.85l24.45-24.43
			                c-14.85-13.83-34.21-22.32-57.32-22.32c-33.47,0-62.46,19.2-76.56,47.18l28.46,22.08C329.56,333.36,348.52,318.3,370.87,318.3z'></path>
	                </g>
                </g>
             </svg>
             <p class='d-flex h-100 align-items-center mb-0'>Google Pay</p>
      </div>
</a>
`,
            }));

        })
    };
}));
