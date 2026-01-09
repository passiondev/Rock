System.register(['tslib', 'vue'], (function (exports) {
    'use strict';
    var __awaiter, defineComponent, ref, computed;
    return {
        setters: [function (module) {
            __awaiter = module.__awaiter;
        }, function (module) {
            defineComponent = module.defineComponent;
            ref = module.ref;
            computed = module.computed;
        }],
        execute: (function () {

            var ApplePay = exports('default', defineComponent({
                name: "ApplePay",
                props: {
                    applePayButtonClasses: {
                        type: [String],
                        required: true,
                    },
                    applePayIconClasses: {
                        type: [String],
                        required: true,
                    },
                    loadingButtonClasses: {
                        type: [String],
                        required: true,
                    },
                    activateApplePay: {
                        type: Function,
                        required: true,
                    },
                    handleResponse: {
                        type: Function,
                        required: true,
                    },
                    gatewayUrl: {
                        type: String,
                        required: true,
                    },
                    appleMerchantId: {
                        type: String,
                        required: true,
                    },
                    applePayCertificateId: {
                        type: String,
                        required: true,
                    },
                    domainName: {
                        type: String,
                        required: true,
                    },
                },
                setup(props, { emit }) {
                    const applePayContainer = ref();
                    const activateApplePay = () => {
                        return props.activateApplePay();
                    };
                    const applePayIconClasses = computed(() => {
                        return props.applePayIconClasses;
                    });
                    const applePayButtonClasses = computed(() => {
                        return props.applePayButtonClasses;
                    });
                    const loadingButtonClasses = computed(() => {
                        return props.loadingButtonClasses;
                    });
                    const onApplePayClick = () => {
                        const ap = new window["walletjs"]["ApplePay"](applePaySettings());
                        const submitApplePay = (tokenizer) => __awaiter(this, void 0, void 0, function* () {
                            var response = yield tokenizer.submit();
                            return response;
                        });
                        submitApplePay(ap)
                            .then((resp) => {
                            handleResponse(resp);
                        })
                            .catch((error) => console.log("error" + JSON.stringify(error, null, 2)));
                    };
                    var gatewayDomain = props.gatewayUrl.replace(/^https?\:\/\//i, "");
                    const jquery = window["$"];
                    const paymentAmountText = jquery('.registrationentry-payment div:contains("Payment Amount")').text();
                    var totalAmount = parseFloat(paymentAmountText.replace(/[^.0-9]/g, ""));
                    const applePaySettings = () => {
                        return {
                            key: props.applePayCertificateId,
                            domain: gatewayDomain,
                            domainName: props.domainName,
                            payment: {
                                merchantCapabilities: [
                                    "supports3DS",
                                    "supportsCredit",
                                    "supportsDebit",
                                ],
                                supportedNetworks: ["visa", "masterCard", "amex", "discover"],
                                countryCode: "US",
                                version: 3,
                                merchantIdentifier: props.appleMerchantId,
                                requiredBillingContactFields: ["postalAddress"],
                            },
                            details: {
                                total: {
                                    label: "Gift Amount",
                                    amount: { currency: "USD", value: totalAmount },
                                },
                            },
                            options: {},
                        };
                    };
                    const handleResponse = function (response) {
                        var _a, _b, _c, _d;
                        if ((response === null || response === void 0 ? void 0 : response.status) === "fail") {
                            emit("loading", false);
                            const errorResponse = response || null;
                            if (errorResponse === null || errorResponse === void 0 ? void 0 : errorResponse.error.includes("The operation was aborted.")) {
                                emit("error", "");
                                console.error("MyWell response was errored:", JSON.stringify(response));
                                return;
                            }
                            else {
                                emit("error", (errorResponse === null || errorResponse === void 0 ? void 0 : errorResponse.error) ||
                                    "There was an unexpected problem with the apple pay payment method.");
                                console.error("MyWell response was errored:", JSON.stringify(response));
                                return;
                            }
                        }
                        if (!(response === null || response === void 0 ? void 0 : response.status) || response.status === "error") {
                            const errorResponse = response || null;
                            emit("loading", false);
                            emit("error", (errorResponse === null || errorResponse === void 0 ? void 0 : errorResponse.message) ||
                                "There was an unexpected problem communicating with the gateway.");
                            console.error("MyWell response was errored:", JSON.stringify(response));
                            return;
                        }
                        if (response.status === "success") {
                            const fluidPayResponse = response || null;
                            if (fluidPayResponse == null ||
                                ((_a = fluidPayResponse.raw_response) === null || _a === void 0 ? void 0 : _a.details.billingContact) == null) {
                                emit("loading", false);
                                emit("error", "There was an error with the billing address.");
                                console.error("MyWell response does not have the expected token:", JSON.stringify(response));
                                return;
                            }
                            const { addressLines, locality, administrativeArea, postalCode, countryCode, } = fluidPayResponse.raw_response.details.billingContact;
                            const billingAddress = {
                                address: addressLines[0],
                                city: locality,
                                state: administrativeArea,
                                zip: postalCode,
                                country: countryCode,
                            };
                            const successfulResponse = {
                                status: fluidPayResponse.status,
                                currencyType: 2,
                                displayName: (_d = (_c = (_b = fluidPayResponse.raw_response) === null || _b === void 0 ? void 0 : _b.details.token) === null || _c === void 0 ? void 0 : _c.paymentMethod) === null || _d === void 0 ? void 0 : _d.displayName,
                                token: fluidPayResponse.token,
                                billing: billingAddress,
                            };
                            emit("success", JSON.stringify(successfulResponse));
                            return;
                        }
                        emit("loading", false);
                        emit("error", "There was an unexpected problem communicating with the gateway.");
                        console.error("MyWell response has invalid status:", JSON.stringify(response));
                    };
                    return {
                        applePayContainer,
                        applePayButtonClasses,
                        activateApplePay,
                        onApplePayClick,
                        applePayIconClasses,
                        loadingButtonClasses,
                    };
                },
                template: `
<a class="js-payment-applepay payment-applepay rounded-pill d-flex w-100 justify-content-center align-items-center m-0" :class="applePayButtonClasses,loadingButtonClasses" @click.prevent="activateApplePay" style="border:none">
    <div class="d-flex pt-2 pb-2 align-items-center">
        <i :class="applePayIconClasses" class="fab fa-apple-pay fa-2x align-items-center fa-border pt-0 pb-0 border-black mr-3"></i><p class='d-flex h-100 align-items-center m-0'>Apple Pay</p>
    </div>
</a>
`,
            }));

        })
    };
}));
