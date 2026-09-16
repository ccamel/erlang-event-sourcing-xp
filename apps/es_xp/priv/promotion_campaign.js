function main(input) {
  switch (input.op) {
    case "init":
      return {state: {status: "new", budget_remaining: 0, claims: []}};
    case "decide":
      return decide(input.command, input.state);
    case "apply":
      return {state: apply(input.event, input.state)};
    default:
      return {error: "invalid_operation"};
  }
}

function decide(command, state) {
  const payload = command.payload;

  if (command.type === "open_campaign" && state.status === "new" &&
      Number.isInteger(payload.budget) && payload.budget > 0) {
    return {events: [{type: "campaign_opened", budget: payload.budget}]};
  }

  if (command.type === "claim_discount" && state.status === "open" &&
      typeof payload.customer_id === "string" &&
      Number.isInteger(payload.cart_total) && payload.cart_total > 0 &&
      ["gold", "standard"].includes(payload.tier)) {
    if (state.claims.some(claim => claim.customer_id === payload.customer_id)) {
      return {error: "already_claimed"};
    }

    const rate = payload.tier === "gold" ? 0.20 : 0.10;
    const amount = Math.floor(payload.cart_total * rate);
    if (amount > state.budget_remaining) {
      return {error: "budget_exhausted"};
    }

    return {events: [{
      type: "discount_granted",
      customer_id: payload.customer_id,
      amount
    }]};
  }

  if (command.type === "close_campaign" && state.status === "open") {
    return {events: [{type: "campaign_closed"}]};
  }

  return {error: "invalid_command"};
}

function apply(event, state) {
  switch (event.type) {
    case "campaign_opened":
      return {...state, status: "open", budget_remaining: event.budget};
    case "discount_granted":
      return {
        ...state,
        budget_remaining: state.budget_remaining - event.amount,
        claims: [...state.claims, {
          customer_id: event.customer_id,
          amount: event.amount
        }]
      };
    case "campaign_closed":
      return {...state, status: "closed"};
    default:
      throw new Error(`unknown event: ${event.type}`);
  }
}
