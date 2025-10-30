# API Manual

## Base URL
```
https://cgmgt7rdl4.execute-api.ap-northeast-2.amazonaws.com
```

## Endpoints Overview

This API provides three main endpoints:
- `/presign` - Pre-signed URL generation
- `/healthz` - Health check endpoint
- `/invocations` - Image processing inference endpoint

---

## 1. `/presign`

Pre-signed URL generation endpoint for S3 operations.

### Method
`POST`

### Description
Generates pre-signed URLs for secure S3 access.

---

## 2. `/healthz`

Health check endpoint.

### Method
`GET`

### Description
Returns the health status of the API service.

### Response
- `200 OK` - Service is healthy

---

## 3. `/invocations`

Image processing inference endpoint.

### Method
`POST`

### Description
Performs deep denoising inference on TIFF images stored in S3.
Only TIFF input files are supported.
This endpoint applies denoising using either the "efficient" or "powerful" model and saves the processed result back to S3.

### Request Headers
```
Content-Type: application/json
```

### Request Body Parameters

| Field            | Type    | Required | Constraints                                 | Description                                                                                                                   |
| ---------------- | ------- | -------- | ------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `model`          | string  | Yes      | Must be one of: `"efficient"`, `"powerful"` | Inference model type                                                                                                          |
| `type`           | string  | Yes      | Must be `"static"`                          | Processing type (fixed value)                                                                                                 |
| `pixel_pitch`    | number  | Yes      | Numeric value                               | Sensor pixel pitch (e.g., 99 or 140)                                                                                          |
| `img_input_url`  | string  | Yes      | Must start with `s3://`                     | S3 URL of the **input TIFF** image.<br>Example: `s3://ddn-in-bucket/user/static_demo_140um_madible_VD.tif`                    |
| `img_output_url` | string  | Yes      | Must start with `s3://`                     | S3 URL to save the **processed output bytes**.<br>Example: `s3://ddn-out-bucket/user/output_static_demo_140um_madible_VD.tif` |
| `digital_offset` | integer | Yes      | Integer                                     | Preprocessing parameter for digital offset                                                                                    |
| `using_bits`     | integer | Yes      | Typically 16                                | Bit depth of the input image.<br>If 16 but TIFF is not `uint16`, a warning is logged                                          |
| `strength`       | integer | Yes      | 0 ≤ strength ≤ 20                           | Denoising strength; internally normalized (0.0–1.0).<br>Values outside this range will return HTTP 400                        |
| `width`          | integer | Yes      | Positive integer                            | Expected input image width.<br>Actual TIFF dimensions override this value                                                     |
| `height`         | integer | Yes      | Positive integer                            | Expected input image height.<br>Actual TIFF dimensions override this value                                                    |

### Request Example

```json
{
  "model": "efficient",
  "type": "static",
  "pixel_pitch": 140,
  "img_input_url": "s3://ddn-in-bucket/user/static_demo_140um_madible_VD.tif",
  "img_output_url": "s3://ddn-out-bucket/user/output_static_demo_140um_madible_VD.tif",
  "digital_offset": 100,
  "using_bits": 16,
  "strength": 10,
  "width": 3072,
  "height": 3072
}
```

### Response

#### Success Response
**HTTP Status:** `200 OK`

```json
{
  "model": "efficient",
  "type": "static",
  "pixel_pitch": 140,
  "img_input_url": "s3://ddn-in-bucket/user/static_demo_140um_madible_VD.tif",
  "img_output_url": "s3://ddn-out-bucket/user/output_static_demo_140um_madible_VD.tif",
  "digital_offset": 100,
  "using_bits": 16,
  "strength": 10,
  "width": 3072,
  "height": 3072
}
```

#### Error Responses

**HTTP Status:** `400 Bad Request`
- Invalid `strength` value (outside 0-20 range)
- Missing required parameters
- Invalid parameter types

```json
{
  "error": "Invalid parameter",
  "message": "strength must be between 0 and 20"
}
```

**HTTP Status:** `500 Internal Server Error`
- Processing failure
- S3 access errors

```json
{
  "error": "Processing failed",
  "message": "Error details"
}
```

### Important Notes

1. **Model Selection**: Currently only `deep_denoising_inference_core` is supported
2. **Image Format**: Input must be a TIFF image stored in S3
3. **Bit Depth Warning**: If `using_bits` is set to 16 but the TIFF file is not uint16 format, a warning will be logged, but processing will continue
4. **Dimension Override**: The `width` and `height` parameters serve as expected values, but actual TIFF dimensions will be used if they differ
5. **Strength Normalization**: The `strength` parameter (0-20) is internally normalized to a 0.0-1.0 range for processing
6. **S3 Permissions**: Ensure the service has appropriate IAM permissions to read from `img_input_url` and write to `img_output_url`

### Processing Flow

1. Input validation for all required parameters
2. Validate `strength` is within 0-20 range
3. Load the specified image processing unit based on `type` parameter
4. Download TIFF image from `img_input_url`
5. Verify image dimensions and bit depth
6. Apply digital offset preprocessing
7. Perform deep denoising inference with normalized strength
8. Save processed output to `img_output_url`
9. Return success response

---

## Error Codes Summary

| HTTP Code | Description |
|-----------|-------------|
| 200 | Success - Request processed successfully |
| 400 | Bad Request - Invalid parameters or validation failure |
| 500 | Internal Server Error - Processing or infrastructure failure |

## Support

For issues or questions regarding this API, please contact the development team.
