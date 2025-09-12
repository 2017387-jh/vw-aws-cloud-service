{
  "family": "${DDN_ECS_TASK_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["EC2"],
  "cpu": "2048",
  "memory": "4096",
  "executionRoleArn": "${DDN_ECS_TASK_ROLE_ARN}",
  "taskRoleArn": "${DDN_ECS_TASK_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "${DDN_ECS_CONTAINER}",
      "image": "${DDN_IMAGE_URI}",
      "essential": true,
      "entryPoint": ["sh","-c"],
      "command": ["tritonserver --model-repository=/opt/ml/model --http-port=${DDN_TRITON_HTTP_PORT} --grpc-port=${DDN_TRITON_GRPC_PORT} & python3 /opt/program/inference_handler.py & wait"],
      "portMappings": [
        { "containerPort": ${DDN_FLASK_PORT}, "protocol": "tcp" },
        { "containerPort": ${DDN_TRITON_HTTP_PORT}, "protocol": "tcp" },
        { "containerPort": ${DDN_TRITON_GRPC_PORT}, "protocol": "tcp" }
      ],
      "environment": [
        { "name": "HTTP_SERVER_PORT", "value": "${DDN_TRITON_HTTP_PORT}"},
        { "name": "GRPC_SERVER_PORT", "value": "${DDN_TRITON_GRPC_PORT}"},
        { "name": "MODEL_STORE", "value": "/opt/ml/model"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "/ecs/${DDN_ECS_TASK_FAMILY}",
          "awslogs-region": "${AWS_REGION}",
          "awslogs-stream-prefix": "app"
        }
      },
      "linuxParameters": {
        "initProcessEnabled": true
      },
      "resourceRequirements": [
        { "type": "GPU", "value": "1" }
      ]
    }
  ]
}
