{
  "family": "${DDN_ECS_TASK_FAMILY}",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["EC2"],
  "cpu": "2048",
  "memory": "8192",
  "executionRoleArn": "${DDN_ECS_EXECUTION_ROLE_ARN}",
  "taskRoleArn": "${DDN_ECS_TASK_ROLE_ARN}",
  "containerDefinitions": [
    {
      "name": "${DDN_ECS_CONTAINER}",
      "image": "${DDN_IMAGE_URI}",
      "essential": true,
      "entryPoint": ["sh","-c"],
      "command": ["tritonserver --model-repository=/opt/ml/model --http-port=${DDN_TRITON_HTTP_PORT} --grpc-port=${DDN_TRITON_GRPC_PORT} & python3 /opt/program/inference_handler.py & wait"],
      "portMappings": [
        { "containerPort": ${DDN_FLASK_HTTP_PORT}, "protocol": "tcp" },
        { "containerPort": ${DDN_FLASK_GRPC_PORT}, "protocol": "tcp" },
        { "containerPort": ${DDN_TRITON_HTTP_PORT}, "protocol": "tcp" },
        { "containerPort": ${DDN_TRITON_GRPC_PORT}, "protocol": "tcp" }
      ],
      "environment": [
        { "name": "MODEL_STORE", "value": "/opt/ml/model"},
        { "name": "APP_LOG_DIR", "value": "/app/logs"},
        { "name": "HTTP_SERVER_PORT", "value": "${DDN_FLASK_HTTP_PORT}"},
        { "name": "GRPC_SERVER_PORT", "value": "${DDN_FLASK_GRPC_PORT}"},
        { "name": "DDN_IN_BUCKET", "value": "${DDN_IN_BUCKET}"},
        { "name": "DDN_OUT_BUCKET", "value": "${DDN_OUT_BUCKET}"}
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
