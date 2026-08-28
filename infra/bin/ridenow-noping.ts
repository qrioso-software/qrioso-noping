#!/usr/bin/env node
import * as cdk from "aws-cdk-lib";
import { RidenowNoPingCoreStack } from "../lib/ridenow-noping-core-stack";
import { RidenowNoPingEdgeStack } from "../lib/ridenow-noping-edge-stack";

function requiredName(value: string, variableName: string): string {
  if (!/^[a-z][a-z0-9-]{1,19}$/.test(value)) {
    throw new Error(`${variableName} debe usar minúsculas, números o guiones y tener 2-20 caracteres.`);
  }
  return value;
}

const app = new cdk.App();
const prefix = requiredName(process.env.PROJECT_PREFIX ?? "ridenow", "PROJECT_PREFIX");
const stage = requiredName(process.env.STAGE ?? "dev", "STAGE");
const region = process.env.CDK_DEFAULT_REGION ?? process.env.AWS_REGION ?? "us-east-1";

if (region !== "us-east-1") {
  throw new Error(`El MVP solo admite AWS_REGION=us-east-1; recibido: ${region}`);
}

const commonEnvironment = {
  account: process.env.CDK_DEFAULT_ACCOUNT,
  region,
};
const core = new RidenowNoPingCoreStack(app, `${prefix}-noping-${stage}-core`, {
  synthesizer: new cdk.BootstraplessSynthesizer(),
  env: commonEnvironment,
  prefix,
  stage,
  instanceType: process.env.INSTANCE_TYPE ?? "t4g.small",
  amiId: process.env.RELAY_AMI_ID ?? "ami-068e33c5263812a9b",
  maxClients: Number.parseInt(process.env.MAX_CLIENTS ?? "10", 10),
  monthlyBudgetUsd: Number.parseFloat(process.env.MONTHLY_BUDGET_USD ?? "60"),
  budgetEmail: process.env.BUDGET_EMAIL,
  awsProfile: process.env.AWS_PROFILE ?? "ridenow-main",
  description: "RideNow NoPing persistent core: EC2, EIP, VPC, SSM, alarms and budget",
});

const edge = new RidenowNoPingEdgeStack(app, `${prefix}-noping-${stage}-edge`, {
  synthesizer: new cdk.BootstraplessSynthesizer(),
  env: commonEnvironment,
  prefix,
  stage,
  description: "RideNow NoPing ephemeral edge: Global Accelerator",
});
