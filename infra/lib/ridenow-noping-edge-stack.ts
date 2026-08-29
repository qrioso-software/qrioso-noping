import {
  CfnParameter,
  CfnOutput,
  Stack,
  StackProps,
  Tags,
  aws_globalaccelerator as globalaccelerator,
} from "aws-cdk-lib";
import { Construct } from "constructs";

export interface RidenowNoPingEdgeStackProps extends StackProps {
  readonly prefix: string;
  readonly stage: string;
}

export class RidenowNoPingEdgeStack extends Stack {
  constructor(scope: Construct, id: string, props: RidenowNoPingEdgeStackProps) {
    super(scope, id, props);

    const baseName = `${props.prefix}-noping-${props.stage}`;

    Tags.of(this).add("Project", `${props.prefix}-noping`);
    Tags.of(this).add("Stage", props.stage);
    Tags.of(this).add("ManagedBy", "aws-cdk");
    Tags.of(this).add("Lifecycle", "ephemeral-edge");

    const relayInstanceId = new CfnParameter(this, "RelayInstanceId", {
      type: "AWS::EC2::Instance::Id",
      description: "EC2 instance ID from the persistent core stack",
    });

    const accelerator = new globalaccelerator.CfnAccelerator(this, "Accelerator", {
      name: `${baseName}-ga`,
      enabled: true,
      ipAddressType: "IPV4",
      tags: [{ key: "Name", value: `${baseName}-ga` }],
    });
    const listener = new globalaccelerator.CfnListener(this, "AcceleratorUdpListener", {
      acceleratorArn: accelerator.attrAcceleratorArn,
      protocol: "UDP",
      portRanges: [{ fromPort: 51821, toPort: 51821 }],
      clientAffinity: "NONE",
    });
    new globalaccelerator.CfnEndpointGroup(this, "AcceleratorEndpointGroup", {
      listenerArn: listener.attrListenerArn,
      endpointGroupRegion: this.region,
      endpointConfigurations: [
        {
          endpointId: relayInstanceId.valueAsString,
          clientIpPreservationEnabled: true,
          weight: 128,
        },
      ],
      healthCheckIntervalSeconds: 10,
      healthCheckPath: "/healthz",
      healthCheckPort: 8080,
      healthCheckProtocol: "HTTP",
      thresholdCount: 3,
      trafficDialPercentage: 100,
    });

    new CfnOutput(this, "AcceleratorArn", {
      value: accelerator.attrAcceleratorArn,
      description: "Global Accelerator ARN; this resource is deleted by infra-down",
    });
    new CfnOutput(this, "AcceleratorDnsName", {
      value: accelerator.attrDnsName,
      description: "Accelerated WireGuard endpoint on UDP 51821",
    });
  }
}
