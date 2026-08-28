import {
  Aws,
  CfnOutput,
  Duration,
  Stack,
  StackProps,
  Tags,
  Validations,
  aws_budgets as budgets,
  aws_cloudwatch as cloudwatch,
  aws_ec2 as ec2,
  aws_iam as iam,
} from "aws-cdk-lib";
import { Construct } from "constructs";

export interface RidenowNoPingCoreStackProps extends StackProps {
  readonly prefix: string;
  readonly stage: string;
  readonly instanceType: string;
  readonly amiId: string;
  readonly maxClients: number;
  readonly monthlyBudgetUsd: number;
  readonly budgetEmail?: string;
  readonly awsProfile: string;
}

export class RidenowNoPingCoreStack extends Stack {
  public readonly relayInstance: ec2.Instance;

  constructor(scope: Construct, id: string, props: RidenowNoPingCoreStackProps) {
    super(scope, id, props);

    if (!Number.isInteger(props.maxClients) || props.maxClients < 1 || props.maxClients > 50) {
      throw new Error("MAX_CLIENTS debe ser un entero entre 1 y 50 para el MVP.");
    }
    if (!Number.isFinite(props.monthlyBudgetUsd) || props.monthlyBudgetUsd <= 0) {
      throw new Error("MONTHLY_BUDGET_USD debe ser mayor que cero.");
    }

    const baseName = `${props.prefix}-noping-${props.stage}`;
    const projectTag = `${props.prefix}-noping`;

    Tags.of(this).add("Project", projectTag);
    Tags.of(this).add("Stage", props.stage);
    Tags.of(this).add("ManagedBy", "aws-cdk");
    Tags.of(this).add("Lifecycle", "persistent-core");

    const vpc = new ec2.Vpc(this, "Vpc", {
      vpcName: `${baseName}-vpc`,
      ipAddresses: ec2.IpAddresses.cidr("10.77.0.0/24"),
      maxAzs: 1,
      natGateways: 0,
      subnetConfiguration: [
        {
          name: `${baseName}-public`,
          subnetType: ec2.SubnetType.PUBLIC,
          cidrMask: 27,
        },
      ],
    });

    const securityGroup = new ec2.SecurityGroup(this, "RelaySecurityGroup", {
      vpc,
      securityGroupName: `${baseName}-relay-sg`,
      description: "RideNow NoPing relay data plane and access API",
      allowAllOutbound: true,
    });
    securityGroup.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.udp(51820), "WireGuard direct path");
    securityGroup.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.udp(51821), "WireGuard accelerated path");
    securityGroup.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(8443), "Access API over TLS");
    securityGroup.addIngressRule(ec2.Peer.anyIpv4(), ec2.Port.tcp(8080), "Global Accelerator health check");

    const role = new iam.Role(this, "RelayRole", {
      roleName: `${baseName}-relay-role`,
      assumedBy: new iam.ServicePrincipal("ec2.amazonaws.com"),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName("AmazonSSMManagedInstanceCore"),
      ],
    });
    role.addToPolicy(new iam.PolicyStatement({
      actions: ["cloudwatch:PutMetricData"],
      resources: ["*"],
      conditions: {
        StringEquals: {
          "cloudwatch:namespace": `${props.prefix}/NoPing`,
        },
      },
    }));

    const userData = ec2.UserData.forLinux();
    userData.addCommands(
      "set -euxo pipefail",
      "dnf install -y wireguard-tools nftables jq python3",
      `getent group ${props.prefix} >/dev/null || groupadd --system ${props.prefix}`,
      `id ${props.prefix} >/dev/null 2>&1 || useradd --system --gid ${props.prefix} --home-dir /var/lib/${props.prefix}-noping --create-home --shell /sbin/nologin ${props.prefix}`,
      `install -d -m 0750 -o root -g ${props.prefix} /etc/${props.prefix}-noping`,
      `install -d -m 0750 -o ${props.prefix} -g ${props.prefix} /var/lib/${props.prefix}-noping`,
      `install -d -m 0750 -o ${props.prefix} -g ${props.prefix} /var/lib/${props.prefix}-noping/health`,
      `printf 'ok\\n' > /var/lib/${props.prefix}-noping/health/healthz`,
      `chown ${props.prefix}:${props.prefix} /var/lib/${props.prefix}-noping/health/healthz`,
      `if [ ! -f /etc/${props.prefix}-noping/access-keys.yaml ]; then printf 'version: 1\\nkeys: {}\\n' > /etc/${props.prefix}-noping/access-keys.yaml; fi`,
      `chown root:${props.prefix} /etc/${props.prefix}-noping/access-keys.yaml`,
      `chmod 0640 /etc/${props.prefix}-noping/access-keys.yaml`,
      "cat >/etc/sysctl.d/90-ridenow-noping.conf <<'EOF'",
      "net.ipv4.ip_forward=1",
      "net.ipv4.conf.all.rp_filter=0",
      "net.ipv4.conf.default.rp_filter=0",
      "EOF",
      "sysctl --system",
      "systemctl enable --now nftables",
      "cat >/etc/systemd/system/ridenow-health.service <<'EOF'",
      "[Unit]",
      "Description=RideNow Global Accelerator health responder",
      "After=network-online.target",
      "Wants=network-online.target",
      "",
      "[Service]",
      `User=${props.prefix}`,
      `Group=${props.prefix}`,
      `WorkingDirectory=/var/lib/${props.prefix}-noping/health`,
      "ExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory .",
      "Restart=always",
      "RestartSec=2",
      "NoNewPrivileges=true",
      "PrivateTmp=true",
      "ProtectHome=true",
      "ProtectSystem=strict",
      "",
      "[Install]",
      "WantedBy=multi-user.target",
      "EOF",
      "systemctl daemon-reload",
      "systemctl enable --now ridenow-health.service",
    );

    this.relayInstance = new ec2.Instance(this, "RelayInstance", {
      instanceName: `${baseName}-relay`,
      vpc,
      vpcSubnets: { subnetType: ec2.SubnetType.PUBLIC },
      instanceType: new ec2.InstanceType(props.instanceType),
      machineImage: ec2.MachineImage.genericLinux({
        [this.region]: props.amiId,
      }),
      securityGroup,
      role,
      userData,
      blockDevices: [
        {
          deviceName: "/dev/xvda",
          volume: ec2.BlockDeviceVolume.ebs(10, {
            encrypted: true,
            volumeType: ec2.EbsDeviceVolumeType.GP3,
            deleteOnTermination: true,
          }),
        },
      ],
    });

    const cfnInstance = this.relayInstance.node.defaultChild as ec2.CfnInstance;
    cfnInstance.sourceDestCheck = false;
    cfnInstance.metadataOptions = {
      httpEndpoint: "enabled",
      httpTokens: "required",
    };
    Validations.of(cfnInstance).acknowledge({
      id: "CloudFormation-Validate::W9010",
      reason: "The ARM64 AMI is intentionally pinned to prevent silent EC2 replacement and loss of the local access-key file.",
    });

    const elasticIp = new ec2.CfnEIP(this, "RelayElasticIp", {
      domain: "vpc",
      tags: [{ key: "Name", value: `${baseName}-eip` }],
    });
    const eipAssociation = new ec2.CfnEIPAssociation(this, "RelayElasticIpAssociation", {
      allocationId: elasticIp.attrAllocationId,
      instanceId: this.relayInstance.instanceId,
    });
    eipAssociation.node.addDependency(this.relayInstance);

    new cloudwatch.Alarm(this, "RelayCpuAlarm", {
      alarmName: `${baseName}-cpu-high`,
      alarmDescription: "Relay CPU over 70% for 15 minutes",
      metric: new cloudwatch.Metric({
        namespace: "AWS/EC2",
        metricName: "CPUUtilization",
        dimensionsMap: { InstanceId: this.relayInstance.instanceId },
        period: Duration.minutes(5),
        statistic: "Average",
      }),
      threshold: 70,
      evaluationPeriods: 3,
      datapointsToAlarm: 3,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.MISSING,
    });

    new cloudwatch.Alarm(this, "RelayStatusAlarm", {
      alarmName: `${baseName}-status-check-failed`,
      alarmDescription: "EC2 system or instance status check failed",
      metric: new cloudwatch.Metric({
        namespace: "AWS/EC2",
        metricName: "StatusCheckFailed",
        dimensionsMap: { InstanceId: this.relayInstance.instanceId },
        period: Duration.minutes(1),
        statistic: "Maximum",
      }),
      threshold: 1,
      evaluationPeriods: 2,
      datapointsToAlarm: 2,
      comparisonOperator: cloudwatch.ComparisonOperator.GREATER_THAN_OR_EQUAL_TO_THRESHOLD,
      treatMissingData: cloudwatch.TreatMissingData.MISSING,
    });

    const subscribers = props.budgetEmail
      ? [{ address: props.budgetEmail, subscriptionType: "EMAIL" }]
      : undefined;
    new budgets.CfnBudget(this, "MonthlySafetyBudget", {
      budget: {
        budgetName: `${baseName}-monthly-budget`,
        budgetLimit: { amount: props.monthlyBudgetUsd, unit: "USD" },
        budgetType: "COST",
        timeUnit: "MONTHLY",
      },
      notificationsWithSubscribers: subscribers
        ? [50, 80, 100].map((threshold) => ({
            notification: {
              comparisonOperator: "GREATER_THAN",
              notificationType: "ACTUAL",
              threshold,
              thresholdType: "PERCENTAGE",
            },
            subscribers,
          }))
        : undefined,
    });

    new CfnOutput(this, "RelayInstanceId", {
      value: this.relayInstance.instanceId,
      description: "EC2 relay managed with SSM Session Manager",
    });
    new CfnOutput(this, "RelayElasticIpAddress", {
      value: elasticIp.ref,
      description: "Stable direct WireGuard endpoint on UDP 51820",
    });
    new CfnOutput(this, "SsmSessionCommand", {
      value: `aws ssm start-session --target ${this.relayInstance.instanceId} --profile ${props.awsProfile} --region ${Aws.REGION}`,
    });
    new CfnOutput(this, "InitialClientLimit", {
      value: props.maxClients.toString(),
      description: "Operational limit until load tests are completed",
    });
  }
}
